#!/usr/bin/env python3
# -------------------------------------------------------------------------------------------------
# <copyright file="execution.pyx" company="Nautech Systems Pty Ltd">
#  Copyright (C) 2015-2019 Nautech Systems Pty Ltd. All rights reserved.
#  The use of this source code is governed by the license as found in the LICENSE.md file.
#  http://www.nautechsystems.io
# </copyright>
# -------------------------------------------------------------------------------------------------

# cython: language_level=3, boundscheck=False, wraparound=False, nonecheck=False

from decimal import Decimal
from cpython.datetime cimport datetime
from typing import List, Dict

from nautilus_trader.core.precondition cimport Precondition
from nautilus_trader.backtest.models cimport FillModel
from nautilus_trader.model.c_enums.brokerage cimport Broker
from nautilus_trader.model.c_enums.quote_type cimport QuoteType
from nautilus_trader.model.c_enums.order_type cimport OrderType
from nautilus_trader.model.c_enums.order_side cimport OrderSide
from nautilus_trader.model.c_enums.order_status cimport OrderStatus
from nautilus_trader.model.c_enums.market_position cimport MarketPosition, market_position_string
from nautilus_trader.model.currency cimport ExchangeRateCalculator
from nautilus_trader.model.objects cimport ValidString, Symbol, Price, Tick, Bar, Money, Instrument, Quantity
from nautilus_trader.model.order cimport Order
from nautilus_trader.model.position cimport Position
from nautilus_trader.model.events cimport Event, OrderEvent, AccountEvent
from nautilus_trader.model.events cimport OrderSubmitted, OrderAccepted, OrderRejected, OrderWorking
from nautilus_trader.model.events cimport OrderExpired, OrderModified, OrderCancelled, OrderCancelReject
from nautilus_trader.model.events cimport OrderFilled
from nautilus_trader.model.identifiers cimport OrderId, ExecutionId, ExecutionTicket, AccountNumber
from nautilus_trader.common.account cimport Account
from nautilus_trader.common.brokerage cimport CommissionCalculator
from nautilus_trader.common.clock cimport TestClock
from nautilus_trader.common.guid cimport TestGuidFactory
from nautilus_trader.common.logger cimport Logger
from nautilus_trader.common.execution cimport ExecutionClient
from nautilus_trader.trade.commands cimport Command, CollateralInquiry
from nautilus_trader.trade.commands cimport SubmitOrder, SubmitAtomicOrder, ModifyOrder, CancelOrder
from nautilus_trader.portfolio.portfolio cimport Portfolio

# Stop order types
cdef set STOP_ORDER_TYPES = {
    OrderType.STOP_MARKET,
    OrderType.STOP_LIMIT,
    OrderType.MIT}


cdef class BacktestExecClient(ExecutionClient):
    """
    Provides an execution client for the BacktestEngine.
    """

    def __init__(self,
                 list instruments: List[Instrument],
                 bint frozen_account,
                 Money starting_capital,
                 FillModel fill_model,
                 CommissionCalculator commission_calculator,
                 Account account,
                 Portfolio portfolio,
                 TestClock clock,
                 TestGuidFactory guid_factory,
                 Logger logger):
        """
        Initializes a new instance of the BacktestExecClient class.

        :param instruments: The instruments needed for the backtest.
        :param frozen_account: The flag indicating whether the account should be frozen (no pnl applied).
        :param starting_capital: The starting capital for the backtest account (> 0).
        :param commission_calculator: The commission calculator.
        :param clock: The clock for the component.
        :param clock: The GUID factory for the component.
        :param logger: The logger for the component.
        :raises ValueError: If the instruments list contains a type other than Instrument.
        """
        Precondition.list_type(instruments, Instrument, 'instruments')

        super().__init__(account,
                         portfolio,
                         clock,
                         guid_factory,
                         logger)

        # Convert instruments list to dictionary indexed by symbol
        cdef dict instruments_dict = {}      # type: Dict[Symbol, Instrument]
        for instrument in instruments:
            instruments_dict[instrument.symbol] = instrument

        self.instruments = instruments_dict  # type: Dict[Symbol, Instrument]

        self.day_number = 0
        self.frozen_account = frozen_account
        self.starting_capital = starting_capital
        self.account_capital = starting_capital
        self.account_cash_start_day = self.account_capital
        self.account_cash_activity_day = Money.zero()
        self.exchange_calculator = ExchangeRateCalculator()
        self.commission_calculator = commission_calculator
        self.total_commissions = Money.zero()
        self.fill_model = fill_model

        self.current_bids = {}         # type: Dict[Symbol, Price]
        self.current_asks = {}         # type: Dict[Symbol, Price]
        self.working_orders = {}       # type: Dict[OrderId, Order]
        self.atomic_child_orders = {}  # type: Dict[OrderId, List[Order]]
        self.oco_orders = {}           # type: Dict[OrderId, OrderId]

        self._set_slippage_index()
        self.reset_account()

    cpdef void connect(self):
        """
        Connect to the execution service.
        """
        self._log.info("Connected.")
        # Do nothing else

    cpdef void disconnect(self):
        """
        Disconnect from the execution service.
        """
        self._log.info("Disconnected.")
        # Do nothing else

    cpdef void change_fill_model(self, FillModel fill_model):
        """
        Set the fill model to be the given model.
        
        :param fill_model: The fill model to set.
        """
        self.fill_model = fill_model

    cpdef void process_tick(self, Tick tick):
        """
        Update the execution client with the given data.

        :param tick: The tick data to update with.
        """
        self.current_bids[tick.symbol] = tick.bid
        self.current_asks[tick.symbol] = tick.ask
        self._process_market(tick.symbol, tick.bid, tick.ask)

    cpdef void process_bars(
            self,
            Symbol symbol,
            Bar bid_bar,
            Bar ask_bar):
        """
        Process the execution client markets with the given data.
        
        :param symbol: The symbol for the update data.
        :param bid_bar: The bid bar data to update with.
        :param ask_bar: The ask bar data to update with.
        """
        self.current_bids[symbol] = bid_bar.close
        self.current_asks[symbol] = ask_bar.close
        self._process_market(symbol, bid_bar.low, ask_bar.high)

    cdef void _process_market(
            self,
            Symbol symbol,
            Price lowest_bid,
            Price highest_ask):
        # Process the working orders for the given by simulating market dynamics
        # using the lowest bid and highest ask.

        cdef CollateralInquiry command
        cdef datetime time_now = self._clock.time_now()

        if self.day_number is not time_now.day:
            # Set account statistics for new day
            self.day_number = time_now.day
            self.account_cash_start_day = self._account.cash_balance
            self.account_cash_activity_day = Money.zero()

            # Generate command
            command = CollateralInquiry(
            self._guid_factory.generate(),
            self._clock.time_now())
            self._collateral_inquiry(command)

        # Simulate market dynamics
        for order_id, order in self.working_orders.copy().items():  # Copies dict to avoid resize during loop
            if order.symbol != symbol:
                continue  # Order is for a different symbol
            if order.status != OrderStatus.WORKING:
                continue  # Orders status has changed since the loop commenced

            # Check for order fill
            if order.side is OrderSide.BUY:
                if order.type in STOP_ORDER_TYPES:
                    if highest_ask > order.price or (highest_ask == order.price and self.fill_model.is_stop_filled()):
                        del self.working_orders[order.id]  # Remove order from working orders
                        if self.fill_model.is_slipped():
                            self._fill_order(order, Price(order.price + self.slippage_index[order.symbol]))
                        else:
                            self._fill_order(order, order.price)
                        continue  # Continue loop to next order
                elif order.type is OrderType.LIMIT:
                    if highest_ask < order.price or (highest_ask == order.price and self.fill_model.is_limit_filled()):
                        del self.working_orders[order.id]  # Remove order from working orders
                        if self.fill_model.is_slipped():
                            self._fill_order(order, Price(order.price + self.slippage_index[order.symbol]))
                        else:
                            self._fill_order(order, order.price)
                        continue  # Continue loop to next order
            elif order.side is OrderSide.SELL:
                if order.type in STOP_ORDER_TYPES:
                    if lowest_bid < order.price or (lowest_bid == order.price and self.fill_model.is_stop_filled()):
                        del self.working_orders[order.id]  # Remove order from working orders
                        if self.fill_model.is_slipped():
                            self._fill_order(order, Price(order.price - self.slippage_index[order.symbol]))
                        else:
                            self._fill_order(order, order.price)
                        continue  # Continue loop to next order
                elif order.type is OrderType.LIMIT:
                    if lowest_bid > order.price or (lowest_bid == order.price and self.fill_model.is_limit_filled()):
                        del self.working_orders[order.id]  # Remove order from working orders
                        if self.fill_model.is_slipped():
                            self._fill_order(order, Price(order.price - self.slippage_index[order.symbol]))
                        else:
                            self._fill_order(order, order.price)
                        continue  # Continue loop to next order

            # Check for order expiry
            if order.expire_time is not None and time_now >= order.expire_time:
                if order.id in self.working_orders:  # Order may have been removed since loop started
                    del self.working_orders[order.id]
                    self._expire_order(order)

    cpdef void execute_command(self, Command command):
        """
        Execute the given command.
        
        :param command: The command to execute.
        """
        self._execute_command(command)

    cpdef void handle_event(self, Event event):
        """
        Handle the given event.
        
        :param event: The event to handle
        """
        self._handle_event(event)

    cpdef void check_residuals(self):
        """
        Check for any residual objects and log warnings if any are found.
        """
        self._check_residuals()

        for order_list in self.atomic_child_orders.values():
            for order in order_list:
                self._log.warning(f"Residual child-order {order}")

        for order_id in self.oco_orders.values():
            self._log.warning(f"Residual OCO {order_id}")

    cpdef void reset_account(self):
        """
        Resets the account.
        """
        cdef AccountEvent initial_starting = AccountEvent(
            self._account.id,
            Broker.SIMULATED,
            AccountNumber('9999'),
            self._account.currency,
            self.starting_capital,
            self.starting_capital,
            Money.zero(),
            Money.zero(),
            Money.zero(),
            Decimal(0),
            ValidString(),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._account.apply(initial_starting)

    cpdef void reset(self):
        """
        Reset the execution client by returning all stateful internal values to 
        their initial value, whilst preserving any constructed tick data.
        """
        self._log.info(f"Resetting...")
        self._reset()
        self.day_number = 0
        self.account_capital = self.starting_capital
        self.account_cash_start_day = self.account_capital
        self.account_cash_activity_day = Money.zero()
        self.total_commissions = Money.zero()
        self.working_orders = {}       # type: Dict[OrderId, Order]
        self.atomic_child_orders = {}  # type: Dict[OrderId, List[Order]]
        self.oco_orders = {}           # type: Dict[OrderId, OrderId]

        self.reset_account()
        self._log.info("Reset.")

    cdef void _set_slippage_index(self):
        cdef dict slippage_index = {}

        for symbol, instrument in self.instruments.items():
            slippage_index[symbol] = instrument.tick_size

        self.slippage_index = slippage_index


# -- COMMAND EXECUTION --------------------------------------------------------------------------- #

    cdef void _collateral_inquiry(self, CollateralInquiry command):
        # Generate event
        cdef AccountEvent event = AccountEvent(
            self._account.id,
            self._account.broker,
            self._account.account_number,
            self._account.currency,
            self._account.cash_balance,
            self.account_cash_start_day,
            self.account_cash_activity_day,
            self._account.margin_used_liquidation,
            self._account.margin_used_maintenance,
            self._account.margin_ratio,
            self._account.margin_call_status,
            self._guid_factory.generate(),
            self._clock.time_now())

        self._handle_event(event)

    cdef void _submit_order(self, SubmitOrder command):
        # Generate event
        cdef OrderSubmitted submitted = OrderSubmitted(
            command.order.id,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._handle_event(submitted)
        self._process_order(command.order)

    cdef void _submit_atomic_order(self, SubmitAtomicOrder command):
        cdef list atomic_orders = [command.atomic_order.stop_loss]
        if command.atomic_order.has_take_profit:
            atomic_orders.append(command.atomic_order.take_profit)
            self.oco_orders[command.atomic_order.take_profit.id] = command.atomic_order.stop_loss.id
            self.oco_orders[command.atomic_order.stop_loss.id] = command.atomic_order.take_profit.id

        self.atomic_child_orders[command.atomic_order.entry.id] = atomic_orders

        # Generate command
        cdef SubmitOrder submit_order = SubmitOrder(
            command.trader_id,
            command.strategy_id,
            command.position_id,
            command.atomic_order.entry,
            self._guid_factory.generate(),
            self._clock.time_now())

        self._submit_order(submit_order)

    cdef void _cancel_order(self, CancelOrder command):
        if command.order_id not in self.working_orders:
            self._cancel_reject_order(command.order_id, 'cancel order', 'order not found')
            return  # Rejected the cancel order command

        cdef Order order = self.working_orders[command.order_id]

        # Generate event
        cdef OrderCancelled cancelled = OrderCancelled(
            order.id,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        # Remove from working orders (checked it was in dictionary above)
        del self.working_orders[command.order_id]

        self._handle_event(cancelled)
        self._check_oco_order(command.order_id)

    cdef void _modify_order(self, ModifyOrder command):
        if command.order_id not in self.working_orders:
            self._cancel_reject_order(command.order_id, 'modify order', 'order not found')
            return  # Rejected the modify order command

        cdef Order order = self.working_orders[command.order_id]
        cdef Instrument instrument = self.instruments[order.symbol]
        cdef Price current_ask
        cdef Price current_bid

        if order.side is OrderSide.BUY:
            current_ask = self.current_asks[order.symbol]
            if order.type in STOP_ORDER_TYPES:
                if order.price.value < current_ask + (instrument.min_stop_distance * instrument.tick_size):
                    self._cancel_reject_order(order, 'modify order', f'BUY STOP order price of {order.price} is too far from the market, ask={current_ask}')
                    return  # Cannot modify order
            elif order.type is OrderType.LIMIT:
                if order.price.value > current_ask + (instrument.min_limit_distance * instrument.tick_size):
                    self._cancel_reject_order(order, 'modify order', f'BUY LIMIT order price of {order.price} is too far from the market, ask={current_ask}')
                    return  # Cannot modify order
        elif order.side is OrderSide.SELL:
            current_bid = self.current_bids[order.symbol]
            if order.type in STOP_ORDER_TYPES:
                if order.price.value > current_bid - (instrument.min_stop_distance * instrument.tick_size):
                    self._cancel_reject_order(order, 'modify order', f'SELL STOP order price of {order.price} is too far from the market, bid={current_bid}')
                    return  # Cannot modify order
            elif order.type is OrderType.LIMIT:
                if order.price.value < current_bid - (instrument.min_limit_distance * instrument.tick_size):
                    self._cancel_reject_order(order, 'modify order', f'SELL LIMIT order price of {order.price} is too far from the market, bid={current_bid}')
                    return  # Cannot modify order

        # Generate event
        cdef OrderModified modified = OrderModified(
            order.id,
            order.id_broker,
            command.modified_price,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._handle_event(modified)


# -- EVENT HANDLING ------------------------------------------------------------------------------ #

    cdef void _accept_order(self, Order order):
        # Generate event
        cdef OrderAccepted accepted = OrderAccepted(
            order.id,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._handle_event(accepted)

    cdef void _reject_order(self, Order order, str reason):
        # Generate event
        cdef OrderRejected rejected = OrderRejected(
            order.id,
            self._clock.time_now(),
            ValidString(reason),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._handle_event(rejected)
        self._check_oco_order(order.id)
        self._clean_up_child_orders(order.id)

    cdef void _cancel_reject_order(
            self,
            OrderId order_id,
            str response,
            str reason):
        # Generate event
        cdef OrderCancelReject cancel_reject = OrderCancelReject(
            order_id,
            self._clock.time_now(),
            ValidString(response),
            ValidString(reason),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._handle_event(cancel_reject)

    cdef void _expire_order(self, Order order):
        # Generate event
        cdef OrderExpired expired = OrderExpired(
            order.id,
            order.expire_time,
            self._guid_factory.generate(),
            self._clock.time_now())

        self._handle_event(expired)

        cdef OrderId first_child_order_id
        cdef OrderId other_oco_order_id
        if order.id in self.atomic_child_orders:
            # Remove any unprocessed atomic child order OCO identifiers
            first_child_order_id = self.atomic_child_orders[order.id][0].id
            if first_child_order_id in self.oco_orders:
                other_oco_order_id = self.oco_orders[first_child_order_id]
                del self.oco_orders[first_child_order_id]
                del self.oco_orders[other_oco_order_id]
        else:
            self._check_oco_order(order.id)
        self._clean_up_child_orders(order.id)

    cdef void _process_order(self, Order order):
        # Work the given order

        Precondition.not_in(order.id, self.working_orders, 'order.id', 'working_orders')

        cdef Instrument instrument = self.instruments[order.symbol]

        # Check order size is valid or reject
        if order.quantity > instrument.max_trade_size:
            self._reject_order(order,  f'order quantity of {order.quantity} exceeds the maximum trade size of {instrument.max_trade_size}')
            return  # Cannot accept order
        if order.quantity < instrument.min_trade_size:
            self._reject_order(order,  f'order quantity of {order.quantity} is less than the minimum trade size of {instrument.min_trade_size}')
            return  # Cannot accept order

        # Check market exists
        if order.symbol not in self.current_bids:  # Market not initialized
            self._reject_order(order,  f'no market for {order.symbol}')
            return  # Cannot accept order

        cdef Price current_bid = self.current_bids[order.symbol]
        cdef Price current_ask = self.current_asks[order.symbol]

        # Check order price is valid or reject
        if order.side is OrderSide.BUY:
            if order.type is OrderType.MARKET:
                # Accept and fill market orders immediately
                self._accept_order(order)
                if self.fill_model.is_slipped():
                    self._fill_order(order, Price(current_ask + self.slippage_index[order.symbol]))
                else:
                    self._fill_order(order, current_ask)
                return  # Order filled - nothing further to process
            elif order.type in STOP_ORDER_TYPES:
                if order.price.value < current_ask + (instrument.min_stop_distance_entry * instrument.tick_size):
                    self._reject_order(order,  f'BUY STOP order price of {order.price} is too far from the market, ask={current_ask}')
                    return  # Cannot accept order
            elif order.type is OrderType.LIMIT:
                if order.price.value > current_ask + (instrument.min_limit_distance_entry * instrument.tick_size):
                    self._reject_order(order,  f'BUY LIMIT order price of {order.price} is too far from the market, ask={current_ask}')
                    return  # Cannot accept order
        elif order.side is OrderSide.SELL:
            if order.type is OrderType.MARKET:
                # Accept and fill market orders immediately
                self._accept_order(order)
                if self.fill_model.is_slipped():
                    self._fill_order(order, Price(current_bid - self.slippage_index[order.symbol]))
                else:
                    self._fill_order(order, current_bid)
                return  # Order filled - nothing further to process
            elif order.type in STOP_ORDER_TYPES:
                if order.price.value > current_bid - (instrument.min_stop_distance_entry * instrument.tick_size):
                    self._reject_order(order,  f'SELL STOP order price of {order.price} is too far from the market, bid={current_bid}')
                    return  # Cannot accept order
            elif order.type is OrderType.LIMIT:
                if order.price.value < current_bid - (instrument.min_limit_distance_entry * instrument.tick_size):
                    self._reject_order(order,  f'SELL LIMIT order price of {order.price} is too far from the market, bid={current_bid}')
                    return  # Cannot accept order

        # Order is valid and accepted
        self._accept_order(order)

        # Order now becomes working
        self.working_orders[order.id] = order

        # Generate event
        cdef OrderWorking working = OrderWorking(
            order.id,
            OrderId('B' + str(order.id.value)),  # Dummy broker id
            order.symbol,
            order.label,
            order.side,
            order.type,
            order.quantity,
            order.price,
            order.time_in_force,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now(),
            order.expire_time)

        self._handle_event(working)
        self._log.debug(f"{order.id} WORKING at {order.price}.")

    cdef void _fill_order(self, Order order, Price fill_price):
        # Generate event
        cdef OrderFilled filled = OrderFilled(
            order.id,
            ExecutionId('E-' + str(order.id.value)),
            ExecutionTicket('ET-' + str(order.id.value)),
            order.symbol,
            order.side,
            order.quantity,
            fill_price,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        # Adjust account if position exists
        if self._portfolio.is_position_for_order(order.id):
            self._adjust_account(filled)

        self._handle_event(filled)
        self._check_oco_order(order.id)

        # Work any atomic child orders
        if order.id in self.atomic_child_orders:
            for child_order in self.atomic_child_orders[order.id]:
                if not child_order.is_complete:  # The order may already be cancelled or rejected
                    self._process_order(child_order)
            del self.atomic_child_orders[order.id]

    cdef void _clean_up_child_orders(self, OrderId order_id):
        # Clean up any residual child orders from the completed order associated
        # with the given identifier.
        if order_id in self.atomic_child_orders:
            del self.atomic_child_orders[order_id]

    cdef void _check_oco_order(self, OrderId order_id):
        # Check held OCO orders and remove any paired with the given order identifier
        cdef OrderId oco_order_id
        cdef Order oco_order

        if order_id in self.oco_orders:
            oco_order_id = self.oco_orders[order_id]
            oco_order = self._order_book[oco_order_id]
            del self.oco_orders[order_id]
            del self.oco_orders[oco_order_id]

            # Reject any latent atomic child orders
            for atomic_order_id, child_orders in self.atomic_child_orders.items():
                for order in child_orders:
                    if oco_order.equals(order):
                        self._reject_oco_order(order, order_id)

            # Cancel any working OCO orders
            if oco_order_id in self.working_orders:
                self._cancel_oco_order(self.working_orders[oco_order_id], order_id)
                del self.working_orders[oco_order_id]

    cdef void _reject_oco_order(self, Order order, OrderId oco_order_id):
        # order is the OCO order to reject
        # oco_order_id is the other order identifier for this OCO pair

        # Generate event
        cdef OrderRejected event = OrderRejected(
            order.id,
            self._clock.time_now(),
            ValidString(f"OCO order rejected from {oco_order_id}"),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._handle_event(event)

    cdef void _cancel_oco_order(self, Order order, OrderId oco_order_id):
        # order is the OCO order to cancel
        # oco_order_id is the other order identifier for this OCO pair

        # Generate event
        cdef OrderCancelled event = OrderCancelled(
            order.id,
            self._clock.time_now(),
            self._guid_factory.generate(),
            self._clock.time_now())

        self._log.debug(f"OCO order cancelled from {oco_order_id}.")
        self._handle_event(event)

    cdef void _adjust_account(self, OrderEvent event):
        # Adjust the positions based on the given order fill event
        cdef Symbol symbol = self._order_book[event.order_id].symbol
        cdef Instrument instrument = self.instruments[symbol]
        cdef float exchange_rate = self.exchange_calculator.get_rate(
            quote_currency=instrument.quote_currency,
            base_currency=self._account.currency,
            quote_type=QuoteType.BID if event.order_side is OrderSide.SELL else QuoteType.ASK,
            bid_rates=self._build_current_bid_rates(),
            ask_rates=self._build_current_ask_rates())

        cdef Position position = self._portfolio.get_position_for_order(event.order_id)
        cdef Money pnl = self._calculate_pnl(
            direction=position.market_position,
            entry_price=position.average_entry_price,
            exit_price=event.average_price,
            quantity=event.filled_quantity,
            exchange_rate=exchange_rate)

        cdef Money commission = self.commission_calculator.calculate(
            symbol=symbol,
            filled_quantity=event.filled_quantity,
            filled_price=event.average_price,
            exchange_rate=exchange_rate)

        self.total_commissions += commission
        pnl -= commission

        if not self.frozen_account:
            self.account_capital += pnl
            self.account_cash_activity_day += pnl

        cdef AccountEvent account_event = AccountEvent(
            self._account.id,
            self._account.broker,
            self._account.account_number,
            self._account.currency,
            self.account_capital,
            self.account_cash_start_day,
            self.account_cash_activity_day,
            margin_used_liquidation=Money.zero(),
            margin_used_maintenance=Money.zero(),
            margin_ratio=Decimal(0),
            margin_call_status=ValidString(),
            event_id=self._guid_factory.generate(),
            event_timestamp=self._clock.time_now())

        self._handle_event(account_event)

    cdef dict _build_current_bid_rates(self):
        # Return the current currency bid rates in the markets
        cdef dict bid_rates = {}  # type: Dict[str, float]
        for symbol, price in self.current_bids.items():
            bid_rates[symbol.code] = price.as_float()
        return bid_rates

    cdef dict _build_current_ask_rates(self):
        # Return the current currency ask rates in the markets
        cdef dict ask_rates = {}  # type: Dict[str, float]
        for symbol, prices in self.current_asks.items():
            ask_rates[symbol.code] = prices.as_float()
        return ask_rates

    cdef Money _calculate_pnl(
            self,
            MarketPosition direction,
            Price entry_price,
            Price exit_price,
            Quantity quantity,
            float exchange_rate):
        cdef object difference
        if direction is MarketPosition.LONG:
            difference = exit_price - entry_price
        elif direction is MarketPosition.SHORT:
            difference = entry_price - exit_price
        else:
            raise ValueError(f'Cannot calculate the pnl of a {market_position_string(direction)} direction.')

        return Money(difference * quantity.value * Decimal(exchange_rate))
# -------------------------------------------------------------------------------------------------
#  Copyright (C) 2015-2023 Nautech Systems Pty Ltd. All rights reserved.
#  https://nautechsystems.io
#
#  Licensed under the GNU Lesser General Public License Version 3.0 (the "License");
#  You may not use this file except in compliance with the License.
#  You may obtain a copy of the License at https://www.gnu.org/licenses/lgpl-3.0.en.html
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.
# -------------------------------------------------------------------------------------------------

import asyncio

import pytest

from nautilus_trader.adapters.binance.http.client import BinanceHttpClient
from nautilus_trader.adapters.binance.spot.http.user import BinanceSpotUserDataHttpAPI
from nautilus_trader.common.clock import LiveClock
from nautilus_trader.common.logging import Logger


@pytest.mark.skip(reason="WIP")
class TestBinanceUserHttpAPI:
    def setup(self):
        # Fixture Setup
        clock = LiveClock()
        logger = Logger(clock=clock)
        self.client = BinanceHttpClient(  # noqa: S106 (no hardcoded password)
            loop=asyncio.get_event_loop(),
            clock=clock,
            logger=logger,
            key="SOME_BINANCE_API_KEY",
            secret="SOME_BINANCE_API_SECRET",
        )

        self.api = BinanceSpotUserDataHttpAPI(self.client)

    @pytest.mark.asyncio
    async def test_create_listen_key_spot(self, mocker):
        # Arrange
        await self.client.connect()
        mock_send_request = mocker.patch(target="aiohttp.client.ClientSession.request")

        # Act
        await self.api.create_listen_key()

        # Assert
        request = mock_send_request.call_args.kwargs
        assert request["method"] == "POST"
        assert request["url"] == "https://api.binance.com/api/v3/userDataStream"

    @pytest.mark.asyncio
    async def test_ping_listen_key_spot(self, mocker):
        # Arrange
        await self.client.connect()
        mock_send_request = mocker.patch(target="aiohttp.client.ClientSession.request")

        # Act
        await self.api.ping_listen_key(
            key="JUdsZc8CSmMUxg1wJha23RogrT3EuC8eV5UTbAOVTkF3XWofMzWoXtWmDAhy",
        )

        # Assert
        request = mock_send_request.call_args.kwargs
        assert request["method"] == "PUT"
        assert request["url"] == "https://api.binance.com/api/v3/userDataStream"
        assert (
            request["params"]
            == "listenKey=JUdsZc8CSmMUxg1wJha23RogrT3EuC8eV5UTbAOVTkF3XWofMzWoXtWmDAhy"
        )

    @pytest.mark.asyncio
    async def test_close_listen_key_spot(self, mocker):
        # Arrange
        await self.client.connect()
        mock_send_request = mocker.patch(target="aiohttp.client.ClientSession.request")

        # Act
        await self.api.close_listen_key(
            key="JUdsZc8CSmMUxg1wJha23RogrT3EuC8eV5UTbAOVTkF3XWofMzWoXtWmDAhy",
        )

        # Assert
        request = mock_send_request.call_args.kwargs
        assert request["method"] == "DELETE"
        assert request["url"] == "https://api.binance.com/api/v3/userDataStream"
        assert (
            request["params"]
            == "listenKey=JUdsZc8CSmMUxg1wJha23RogrT3EuC8eV5UTbAOVTkF3XWofMzWoXtWmDAhy"
        )

    @pytest.mark.asyncio
    async def test_create_listen_key_isolated_margin(self, mocker):
        # Arrange
        await self.client.connect()
        mock_send_request = mocker.patch(target="aiohttp.client.ClientSession.request")

        # Act
        await self.api.create_listen_key_isolated_margin(symbol="ETHUSDT")

        # Assert
        request = mock_send_request.call_args.kwargs
        assert request["method"] == "POST"
        assert request["url"] == "https://api.binance.com/sapi/v1/userDataStream/isolated"
        assert request["params"] == "symbol=ETHUSDT"

    @pytest.mark.asyncio
    async def test_ping_listen_key_isolated_margin(self, mocker):
        # Arrange
        await self.client.connect()
        mock_send_request = mocker.patch(target="aiohttp.client.ClientSession.request")

        # Act
        await self.api.ping_listen_key_isolated_margin(
            symbol="ETHUSDT",
            key="JUdsZc8CSmMUxg1wJha23RogrT3EuC8eV5UTbAOVTkF3XWofMzWoXtWmDAhy",
        )

        # Assert
        request = mock_send_request.call_args.kwargs
        assert request["method"] == "PUT"
        assert request["url"] == "https://api.binance.com/sapi/v1/userDataStream/isolated"
        assert (
            request["params"]
            == "listenKey=JUdsZc8CSmMUxg1wJha23RogrT3EuC8eV5UTbAOVTkF3XWofMzWoXtWmDAhy&symbol=ETHUSDT"
        )

    @pytest.mark.asyncio
    async def test_close_listen_key_isolated_margin(self, mocker):
        # Arrange
        await self.client.connect()
        mock_send_request = mocker.patch(target="aiohttp.client.ClientSession.request")

        # Act
        await self.api.close_listen_key_isolated_margin(
            symbol="ETHUSDT",
            key="JUdsZc8CSmMUxg1wJha23RogrT3EuC8eV5UTbAOVTkF3XWofMzWoXtWmDAhy",
        )

        # Assert
        request = mock_send_request.call_args.kwargs
        assert request["method"] == "DELETE"
        assert request["url"] == "https://api.binance.com/sapi/v1/userDataStream/isolated"
        assert (
            request["params"]
            == "listenKey=JUdsZc8CSmMUxg1wJha23RogrT3EuC8eV5UTbAOVTkF3XWofMzWoXtWmDAhy&symbol=ETHUSDT"
        )

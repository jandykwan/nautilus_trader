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

import pytest

from nautilus_trader.adapters._template.data import TemplateLiveMarketDataClient  # noqa
from nautilus_trader.live.data_client import LiveMarketDataClient


@pytest.mark.skip(reason="example")
@pytest.fixture()
def data_client() -> LiveMarketDataClient:
    return TemplateLiveMarketDataClient()  # type: ignore


@pytest.mark.skip(reason="example")
def test_connect(data_client: LiveMarketDataClient):
    data_client.connect()
    assert data_client.is_connected


@pytest.mark.skip(reason="example")
def test_disconnect(data_client: LiveMarketDataClient):
    data_client.connect()
    data_client.disconnect()
    assert not data_client.is_connected


@pytest.mark.skip(reason="example")
def test_reset(data_client: LiveMarketDataClient):
    pass


@pytest.mark.skip(reason="example")
def test_dispose(data_client: LiveMarketDataClient):
    pass

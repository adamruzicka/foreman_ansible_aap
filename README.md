# Foreman Ansible AAP

An optional Foreman plugin that provides the experimental Ansible Automation
Platform execution driver for `foreman_ansible`. Smart Proxy execution remains
the default.

## Installation

Add the plugin alongside compatible `foreman_ansible` and
`foreman_remote_execution` versions. Follow the complete
[experimental setup and limitations guide](docs/experimental-aap.md) before
enabling the driver.

## Usage

Set the **Ansible execution driver** setting to **AAP (experimental)** for newly
created Ansible Job Invocations. Each invocation retains the driver selected
when it was created. Smart Proxy execution remains the default, and the AAP
driver is not production-ready or feature-equivalent to proxy execution.

Validation against a real controller is intentionally separate from normal
mocked tests. Use the [AAP 2.6 live-integration
scenario](docs/aap-2.6-live-integration.md) and record observed results without
assuming the scenario has already passed.

## Contributing

Fork and send a Pull Request. Thanks!

## Copyright

Copyright (c) 2026 Foreman Ansible team

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program.  If not, see <http://www.gnu.org/licenses/>.

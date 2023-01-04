# Copyright 2022 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

SELECT
    segments.external_conversion_source AS conversion_source,
    segments.conversion_action_name AS conversion_name,
    segments.conversion_action_category AS conversion_type,
    segments.conversion_action~0 AS conversion_id
FROM campaign
WHERE campaign.advertising_channel_type = "MULTI_CHANNEL"


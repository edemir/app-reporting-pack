-- Table for creative_excellence for on campaign_id level. Some information on
-- ad_group level is available. Contains aggregated performance data
-- (cost, installs, inapps) for the last 7 days.
CREATE OR REPLACE TABLE {bq_project}.{bq_dataset}.creative_excellence_F
AS (
WITH
    -- Calculate ad_group level cost for the last 7 days
    CostDynamicsTable AS (
        SELECT
            ad_group_id,
            `{bq_project}.{bq_dataset}.NormalizeMillis`(SUM(cost)) AS cost_last_7_days
        FROM {bq_project}.{bq_dataset}.ad_group_performance
        WHERE PARSE_DATE("%Y-%m-%d", date)
            BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY) AND CURRENT_DATE()
        GROUP BY 1
    ),
    ConversionSplitTable AS (
        SELECT
            campaign_id,
            ad_group_id,
            SUM(IF(conversion_category = "DOWNLOAD", conversions, 0)) AS installs,
            SUM(IF(conversion_category != "DOWNLOAD", conversions, 0)) AS inapps
        FROM {bq_project}.{bq_dataset}.ad_group_conversion_split
        WHERE PARSE_DATE("%Y-%m-%d", date)
            BETWEEN DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY) AND CURRENT_DATE()
        GROUP BY 1, 2
    ),
    -- Helper to identify campaign level bid and budget snapshot data
    -- for the last 7 days alonside corresponding lags
    BidBudget7DaysTable AS (
        SELECT
            day,
            campaign_id,
            budget_amount,
            LAG(budget_amount) OVER(PARTITION BY campaign_id ORDER BY day) AS budget_amount_last_day,
            target_cpa,
            LAG(target_cpa) OVER(PARTITION BY campaign_id ORDER BY day) AS target_cpa_last_day,
            target_roas,
            LAG(target_roas) OVER(PARTITION BY campaign_id ORDER BY day) AS target_roas_last_day
        FROM `{bq_project}.{bq_dataset}.bid_budgets_*`
        WHERE day >= DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY)
    ),
    -- Average bid and budget data for each campaign for the last 7 days;
    -- counts how many times for a particual campaign bid and budget changes
    -- were greater than 20%
    BidBudgetAvg7DaysTable AS (
        SELECT
            campaign_id,
            COUNT(
                IF(budget_amount / budget_amount_last_day > 1.2
                    OR budget_amount / budget_amount_last_day < 0.8,
                1, 0)
            ) AS dramatic_budget_changes,
            COUNT(
                IF(target_cpa > 0 -- check for campaigns with target_cpa bidding
                    AND (
                        target_cpa / target_cpa_last_day> 1.2
                        OR target_cpa / target_cpa_last_day < 0.8
                    ),
                1, 0)
            ) AS dramatic_target_cpa_changes,
            COUNT(
                IF(target_roas > 0 -- check for campaigns with target_roas bidding
                    AND (
                        target_roas / target_roas_last_day > 1.2
                        OR target_roas / target_roas_last_day < 0.8
                    ),
                1, 0)
            ) AS dramatic_target_roas_changes,
            AVG(`{bq_project}.{bq_dataset}.NormalizeMillis`(budget_amount)) AS average_budget_7_days,
            COALESCE(
                AVG(`{bq_project}.{bq_dataset}.NormalizeMillis`(target_cpa)),
                AVG(target_roas)
            )AS average_bid_7_days
        FROM BidBudget7DaysTable
        GROUP BY 1
    )
SELECT
    M.account_id,
    M.account_name,
    M.currency,
    M.campaign_id,
    M.campaign_name,
    M.campaign_status,
    ACS.campaign_sub_type,
    ACS.app_id,
    ACS.app_store,
    ACS.bidding_strategy,
    ARRAY_TO_STRING(ACS.target_conversions, " | ")  AS target_conversions,
    M.ad_group_id,
    M.ad_group_name,
    M.ad_group_status,
    ARRAY_LENGTH(ACS.target_conversions) AS n_of_target_conversions,
    `{bq_project}.{bq_dataset}.NormalizeMillis`(B.budget_amount) AS budget_amount,
    `{bq_project}.{bq_dataset}.NormalizeMillis`(B.target_cpa) AS target_cpa,
    B.target_roas AS target_roas,
    -- For Installs campaigns the recommend budget amount it 50 times target_cpa
    -- for Action campaigns - 10 times target_cpa
    CASE
        WHEN ACS.bidding_strategy = "OPTIMIZE_INSTALLS_TARGET_INSTALL_COST" AND B.budget_amount/B.target_cpa >= 50 THEN "OK"
        WHEN ACS.bidding_strategy = "OPTIMIZE_INSTALLS_TARGET_INSTALL_COST" AND B.budget_amount/B.target_cpa < 50 THEN "50x needed"
        WHEN ACS.bidding_strategy = "OPTIMIZE_IN_APP_CONVERSIONS_TARGET_CONVERSION_COST" AND B.budget_amount/B.target_cpa >= 10 THEN "OK"
        WHEN ACS.bidding_strategy = "OPTIMIZE_IN_APP_CONVERSIONS_TARGET_CONVERSION_COST" AND B.budget_amount/B.target_cpa < 10 THEN "10x needed"
        ELSE "Not Applicable"
        END AS enough_budget,
    -- number of active assets of a certain type
    `{bq_project}.{bq_dataset}.GetNumberOfElements`(install_videos, engagement_videos, pre_registration_videos) AS n_videos,
    `{bq_project}.{bq_dataset}.GetNumberOfElements`(install_images, engagement_images, pre_registration_images) AS n_images,
    `{bq_project}.{bq_dataset}.GetNumberOfElements`(install_headlines, engagement_headlines, pre_registration_headlines) AS n_headlines,
    `{bq_project}.{bq_dataset}.GetNumberOfElements`(install_descriptions, engagement_descriptions, pre_registration_descriptions) AS n_descriptions,
    ARRAY_LENGTH(SPLIT(install_media_bundles, "|")) - 1 AS n_html5,
    S.ad_strength AS ad_strength,
    IFNULL(C.cost_last_7_days, 0) AS cost_last_7_days,
    IFNULL(
        IF(ACS.bidding_strategy = "OPTIMIZE_INSTALLS_TARGET_INSTALL_COST", Conv.installs, Conv.inapps),
        0) AS conversions_last_7_days,
    CASE
        WHEN ACS.bidding_strategy = "OPTIMIZE_INSTALLS_TARGET_INSTALL_COST" AND SUM(Conv.installs) OVER (PARTITION BY Conv.campaign_id) > 10
            THEN TRUE
        WHEN ACS.bidding_strategy = "OPTIMIZE_INSTALLS_TARGET_INSTALL_COST" AND SUM(Conv.inapps) OVER (PARTITION BY Conv.campaign_id) > 10
            THEN TRUE
        ELSE FALSE
        END AS enough_conversions,
    Avg7Days.average_budget_7_days AS average_budget_7_days,
    Avg7Days.average_bid_7_days AS average_bid_7_days,
    Avg7Days.dramatic_budget_changes AS dramatic_budget_changes,
    COALESCE(
        Avg7Days.dramatic_target_cpa_changes,
        Avg7Days.dramatic_target_roas_changes
    ) AS dramatic_bid_changes
FROM {bq_project}.{bq_dataset}.account_campaign_ad_group_mapping AS M
LEFT JOIN `{bq_project}.{bq_dataset}.AppCampaignSettingsView` AS ACS
  ON M.campaign_id = ACS.campaign_id
LEFT JOIN {bq_project}.{bq_dataset}.bid_budget AS B
    ON M.campaign_id = B.campaign_id
LEFT JOIN {bq_project}.{bq_dataset}.asset_structure AS S
  ON M.ad_group_id = S.ad_group_id
LEFT JOIN CostDynamicsTable AS C
  ON M.ad_group_id = C.ad_group_id
LEFT JOIN ConversionSplitTable AS Conv
  ON M.campaign_id = Conv.campaign_id
  AND M.ad_group_id = Conv.ad_group_id
LEFT JOIN BidBudgetAvg7DaysTable AS Avg7Days
    ON M.campaign_id = Avg7Days.campaign_id
);
-- Wordmark kind (Task 8e). airline_assets.kind is the brand_asset_kind enum; 'logo' is the compact
-- symbol when the provider has one (square slots), 'wordmark' the wide full logo (airline card).
alter type brand_asset_kind add value if not exists 'wordmark';

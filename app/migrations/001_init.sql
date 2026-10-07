-- 001_init: core schema. Applied once by adpulse.migrate (tracked in schema_migrations).
CREATE TABLE IF NOT EXISTS advertisers (
    id   serial PRIMARY KEY,
    name text NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS ads (
    id            serial PRIMARY KEY,
    advertiser_id int NOT NULL REFERENCES advertisers (id),
    category      text NOT NULL,
    segment       text NOT NULL,
    title         text,
    image_url     text,
    click_url     text,
    bid_cpm       numeric(8, 4) NOT NULL CHECK (bid_cpm > 0),
    active        bool DEFAULT true,
    created_at    timestamptz DEFAULT now()
);

CREATE INDEX IF NOT EXISTS ads_category_segment_active_idx
    ON ads (category, segment) WHERE active;

CREATE TABLE IF NOT EXISTS impressions (
    id        bigserial PRIMARY KEY,
    ad_id     int,
    category  text,
    segment   text,
    source    text,
    served_at timestamptz DEFAULT now()
);

-- Also created by adpulse.migrate before any migration runs (it needs it for tracking).
CREATE TABLE IF NOT EXISTS schema_migrations (
    version    text PRIMARY KEY,
    applied_at timestamptz DEFAULT now()
);

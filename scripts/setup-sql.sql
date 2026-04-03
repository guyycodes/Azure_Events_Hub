-- Azure Event-Driven Demo: SQL Table Setup
-- Run this ONCE against your Azure SQL Database before testing.

CREATE TABLE events (
    id          INT IDENTITY(1,1) PRIMARY KEY,
    event_type  NVARCHAR(100)     NOT NULL,
    payload     NVARCHAR(MAX)     NOT NULL,
    received_at DATETIME2         NOT NULL
);

CREATE INDEX IX_events_event_type ON events (event_type);
CREATE INDEX IX_events_received_at ON events (received_at DESC);

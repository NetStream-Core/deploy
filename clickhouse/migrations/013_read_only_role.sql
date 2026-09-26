CREATE ROLE IF NOT EXISTS netstream_reader;

GRANT SELECT ON netstream.* TO netstream_reader;
GRANT SELECT ON system.tables TO netstream_reader;
GRANT SELECT ON system.columns TO netstream_reader;

CREATE USER IF NOT EXISTS netstream_ro IDENTIFIED WITH sha256_password BY 'netstream-ro-dev' DEFAULT ROLE netstream_reader;

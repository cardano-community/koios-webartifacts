CREATE TABLE IF NOT EXISTS grest.pool_active_stake_cache (
  pool_id varchar NOT NULL,
  epoch_no bigint NOT NULL,
  amount lovelace NOT NULL,
  PRIMARY KEY (pool_id, epoch_no)
);

CREATE TABLE IF NOT EXISTS grest.epoch_active_stake_cache (
  epoch_no bigint NOT NULL,
  amount lovelace NOT NULL,
  PRIMARY KEY (epoch_no)
);

CREATE OR REPLACE FUNCTION grest.active_stake_cache_update_check()
RETURNS boolean
LANGUAGE plpgsql
AS $$
DECLARE
  _current_epoch_no integer;
  _last_active_stake_validated_epoch text;
BEGIN
  -- Get Last Active Stake Validated Epoch
  SELECT last_value INTO _last_active_stake_validated_epoch
  FROM grest.control_table
  WHERE key = 'last_active_stake_validated_epoch';
  -- Get Current Epoch
  SELECT MAX(no) INTO _current_epoch_no
  FROM epoch;
  RAISE NOTICE 'Next epoch: %', _current_epoch_no+1;
  RAISE NOTICE 'Latest epoch in active stake cache: %', _last_active_stake_validated_epoch;
  IF _current_epoch_no > COALESCE(_last_active_stake_validated_epoch::integer, 0) THEN
    RETURN TRUE;
  ELSE
    -- If last active stake cache is same as current epoch_no, check if we're beyond 60% within epoch to populate next epoch stake, only valid as of dbsync 13.2.0.0
    -- Todo: Add status check for epoch_stake_progress instead of checking for checking epoch progress being > 60% as part of https://github.com/IntersectMBO/cardano-db-sync/issues/1620
    IF _current_epoch_no = _last_active_stake_validated_epoch::integer
      AND (
        SELECT (
          (SELECT EXTRACT(EPOCH FROM time)::integer
            FROM block ORDER BY id DESC LIMIT 1) - start_time
          ) * 100 / ((end_time - start_time)::integer)
        FROM grest.epoch_info((SELECT MAX(no) FROM epoch))
      ) > 60 THEN
        RETURN TRUE;
    END IF;
  END IF;
  RAISE NOTICE 'Active Stake cache is up to date with DB!';
  RETURN FALSE;
END;
$$;

COMMENT ON FUNCTION grest.active_stake_cache_update_check IS 'Internal function to determine whether active stake cache should be updated'; -- noqa: LT01

CREATE OR REPLACE FUNCTION grest.active_stake_cache_update(_epoch_no integer)
RETURNS void
LANGUAGE plpgsql
AS $$
DECLARE
  _last_active_stake_validated_epoch integer;
BEGIN
    -- CHECK PREVIOUS QUERY FINISHED RUNNING
    IF (
      SELECT COUNT(pid) > 1
      FROM pg_stat_activity
      WHERE state = 'active'
        AND query ILIKE '%grest.active_stake_cache_update(%'
        AND datname = (SELECT current_database())
    ) THEN
      RAISE EXCEPTION
        'Previous query still running but should have completed! Exiting...';
    END IF;
    -- GET PREVIOUS RUN's epoch_no
    SELECT COALESCE(
      (SELECT last_value::integer
        FROM grest.control_table
        WHERE key = 'last_active_stake_validated_epoch'), 0) INTO _last_active_stake_validated_epoch;
    -- POOL ACTIVE STAKE CACHE
    INSERT INTO grest.pool_active_stake_cache
      SELECT
        pool_hash.view AS pool_id,
        epoch_stake.epoch_no,
        SUM(epoch_stake.amount) AS amount
      FROM public.epoch_stake
      INNER JOIN public.pool_hash ON pool_hash.id = epoch_stake.pool_id
      WHERE epoch_stake.epoch_no >= _last_active_stake_validated_epoch
        AND epoch_stake.epoch_no <= _epoch_no
      GROUP BY
        pool_hash.view,
        epoch_stake.epoch_no
    ON CONFLICT (
      pool_id,
      epoch_no
    ) DO UPDATE
      SET amount = excluded.amount
      WHERE pool_active_stake_cache.amount IS DISTINCT FROM excluded.amount;
    -- EPOCH ACTIVE STAKE CACHE
    INSERT INTO grest.epoch_active_stake_cache
      SELECT
        epoch_stake.epoch_no,
        SUM(epoch_stake.amount) AS amount
      FROM public.epoch_stake
      WHERE epoch_stake.epoch_no >= _last_active_stake_validated_epoch
        AND epoch_stake.epoch_no <= _epoch_no
      GROUP BY epoch_stake.epoch_no
      ON CONFLICT (epoch_no) DO UPDATE
        SET amount = excluded.amount
        WHERE epoch_active_stake_cache.amount IS DISTINCT FROM excluded.amount;

    -- CONTROL TABLE ENTRY
    PERFORM grest.update_control_table(
      'last_active_stake_validated_epoch',
      _epoch_no::text
    );
  END;
$$;

COMMENT ON FUNCTION grest.active_stake_cache_update IS 'Internal function to update active stake cache (epoch, pool, and account tables).'; -- noqa: LT01

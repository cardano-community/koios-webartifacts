CREATE OR REPLACE FUNCTION grest.committee_info()
RETURNS TABLE (
  proposal_tx_hash text,
  proposal_index bigint,
  quorum_numerator bigint,
  quorum_denominator bigint,
  members jsonb
)
LANGUAGE plpgsql
AS $$
DECLARE
  gap_id  bigint;
BEGIN

  SELECT INTO gap_id id
  FROM public.gov_action_proposal
  WHERE type = 'NewCommittee'
    AND enacted_epoch IS NOT NULL
  ORDER BY enacted_epoch DESC
  LIMIT 1;

  RETURN QUERY (
    SELECT
      CASE
        WHEN c.gov_action_proposal_id IS NULL THEN NULL
        ELSE (
          SELECT ENCODE(tx.hash, 'hex')
          FROM gov_action_proposal AS gap
          INNER JOIN tx on gap.tx_id = tx.id
          WHERE gap.id = c.gov_action_proposal_id
        )
      END,
      CASE
        WHEN c.gov_action_proposal_id IS NULL THEN NULL
        ELSE (
          SELECT index
          FROM gov_action_proposal AS gap
          WHERE gap.id = c.gov_action_proposal_id
        )
      END,
      c.quorum_numerator,
      c.quorum_denominator,
      JSONB_AGG(
        JSONB_BUILD_OBJECT(
          'cc_cold_hex', ENCODE(ch_cold.raw, 'hex'),
          'cc_cold_has_script', ch_cold.has_script,
          'cc_hot_hex', CASE WHEN hot_key.raw IS NULL THEN NULL ELSE ENCODE(hot_key.raw, 'hex') END,
          'cc_hot_has_script', CASE WHEN hot_key.has_script IS NULL THEN NULL ELSE hot_key.has_script END,
          'expiration_epoch', cm.expiration_epoch
        )
      ) AS members
    FROM public.committee AS c
    INNER JOIN public.committee_member AS cm ON c.id = cm.committee_id
    INNER JOIN public.committee_hash AS ch_cold ON ch_cold.id = cm.committee_hash_id
    LEFT JOIN LATERAL (
      SELECT
        ch_hot.raw,
        ch_hot.has_script
      FROM
        public.committee_registration AS cr
        INNER JOIN public.committee_hash AS ch_hot ON ch_hot.id = cr.hot_key_id
      WHERE
        cr.cold_key_id = ch_cold.id
        AND NOT EXISTS (
          SELECT TRUE
          FROM committee_de_registration AS cdr
          WHERE cdr.cold_key_id = cr.cold_key_id
            AND cdr.tx_id > cr.tx_id
        )
      ORDER BY cr.id DESC
      LIMIT 1
    ) AS hot_key ON TRUE
    WHERE
      CASE
        WHEN gap_id IS NULL THEN c.gov_action_proposal_id IS NULL
        ELSE c.gov_action_proposal_id = gap_id
      END
    GROUP BY c.gov_action_proposal_id, c.quorum_numerator, c.quorum_denominator
  );

END;
$$;

COMMENT ON FUNCTION grest.committee_info IS 'Get information about current governance committee'; --noqa: LT01
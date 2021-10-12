CREATE OR REPLACE PROCEDURE dropPartitionsOf(IN _basetableschema TEXT, IN _basetablename TEXT) AS
$$
DECLARE
    row record;
BEGIN
    FOR row IN
        SELECT nmsp_child.nspname AS child_schema,
               child.relname      AS child
        FROM pg_inherits
                 JOIN pg_class parent ON pg_inherits.inhparent = parent.oid
                 JOIN pg_class child ON pg_inherits.inhrelid = child.oid
                 JOIN pg_namespace nmsp_parent ON nmsp_parent.oid = parent.relnamespace
                 JOIN pg_namespace nmsp_child ON nmsp_child.oid = child.relnamespace
        WHERE parent.relname = _basetablename
          AND nmsp_parent.nspname = _basetableschema
        LOOP
            CALL dropPartitionsOf(row.child_schema, row.child);
            EXECUTE 'DROP TABLE ' || quote_ident(row.child_schema) || '.' || quote_ident(row.child);
            COMMIT;
        END LOOP;
END;
$$ LANGUAGE plpgsql;

CALL dropPartitionsOf('public', 'journal');


DROP TABLE IF EXISTS public.journal;

CREATE TABLE IF NOT EXISTS public.journal
(
    ordering        BIGINT,
    sequence_number BIGINT                NOT NULL,
    deleted         BOOLEAN DEFAULT FALSE NOT NULL,
    persistence_id  TEXT                  NOT NULL,
    message         BYTEA                 NOT NULL,
    tags            int[],
    metadata        jsonb                 NOT NULL,
    PRIMARY KEY (ordering)
) PARTITION BY RANGE (ordering);

CREATE SEQUENCE journal_ordering_seq OWNED BY public.journal.ordering;

CREATE EXTENSION IF NOT EXISTS intarray WITH SCHEMA public;
CREATE INDEX journal_tags_idx ON public.journal USING GIN (tags public.gin__int_ops);

DROP TABLE IF EXISTS public.tags;

CREATE TABLE IF NOT EXISTS public.tags
(
    id   BIGSERIAL,
    name TEXT NOT NULL,
    PRIMARY KEY (id)
);

CREATE UNIQUE INDEX IF NOT EXISTS tags_name_idx on public.tags (name);

DROP TABLE IF EXISTS public.snapshot;

CREATE TABLE IF NOT EXISTS public.snapshot
(
    persistence_id  TEXT   NOT NULL,
    sequence_number BIGINT NOT NULL,
    created         BIGINT NOT NULL,
    snapshot        BYTEA  NOT NULL,
    metadata        jsonb  NOT NULL,
    PRIMARY KEY (persistence_id, sequence_number)
);

DROP TRIGGER IF EXISTS trig_update_journal_persistence_ids ON public.journal;
DROP FUNCTION IF EXISTS public.update_journal_persistence_ids();
DROP TABLE IF EXISTS public.journal_persistence_ids;

CREATE TABLE public.journal_persistence_ids(
  persistence_id TEXT NOT NULL,
  max_sequence_number BIGINT NOT NULL,
  min_ordering BIGINT NOT NULL,
  max_ordering BIGINT NOT NULL,
  PRIMARY KEY (persistence_id)
);

CREATE OR REPLACE FUNCTION public.update_journal_persistence_ids() RETURNS TRIGGER AS
$$
DECLARE
BEGIN
  INSERT INTO public.journal_persistence_ids (persistence_id, max_sequence_number, max_ordering, min_ordering)
  VALUES (NEW.persistence_id, NEW.sequence_number, NEW.ordering, NEW.ordering)
  ON CONFLICT (persistence_id) DO UPDATE
  SET
    max_sequence_number = GREATEST(public.journal_persistence_ids.max_sequence_number, NEW.sequence_number),
    max_ordering = GREATEST(public.journal_persistence_ids.max_ordering, NEW.ordering),
    min_ordering = LEAST(public.journal_persistence_ids.min_ordering, NEW.ordering);

  RETURN NEW;
END;
$$
LANGUAGE plpgsql;

CREATE TRIGGER trig_update_journal_persistence_ids
  AFTER INSERT ON public.journal
  FOR EACH ROW
  EXECUTE PROCEDURE public.update_journal_persistence_ids();

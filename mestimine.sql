-- DROP DATABASE mestimine;
-- CREATE DATABASE mestimine TEMPLATE template0;
-- \c mestimine

-- tag::tabelid[]

CREATE TABLE IF NOT EXISTS public.reegel
(
    reegel_id  smallint    NOT NULL,
    marc_vali  varchar(16) NOT NULL,
    alamvali   varchar(1)  NOT NULL,
    kommentaar text        NOT NULL,
    CONSTRAINT reegel_pk
        PRIMARY KEY (reegel_id),
    CONSTRAINT reegel_marc_vali_alamvali_ak
        UNIQUE (marc_vali, alamvali)
);

COMMENT ON TABLE public.reegel IS 'Mestimisreeglid.';

CREATE TABLE IF NOT EXISTS public.kirje
(
    kirje_nr        integer NOT NULL,
    bkood2          char    NOT NULL,
    bkood3          char    NOT NULL,
    keel            char(3) NOT NULL,
    viimane_uuendus date    NOT NULL,
    sisu            jsonb   NOT NULL,
    CONSTRAINT kirje_pk
        PRIMARY KEY (kirje_nr)
);

COMMENT ON TABLE public.kirje IS 'Bibkirjed.';

CREATE TABLE IF NOT EXISTS public.paar
(
    paar_id      serial,
    aluskirje    integer NOT NULL,
    liituv_kirje integer NOT NULL,
    sarnasus     real    NOT NULL,
    ylekate      real    NOT NULL,
    kaugus       integer NOT NULL,
    CONSTRAINT paar_pk
        PRIMARY KEY (paar_id),
    CONSTRAINT paar_aluskirje_liituv_kirje_ak
        UNIQUE (aluskirje, liituv_kirje),
    CONSTRAINT paar_kirje_aluskirje_fk
        FOREIGN KEY (aluskirje) REFERENCES kirje
            ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT paar_kirje_liituv_kirje_fk
        FOREIGN KEY (liituv_kirje) REFERENCES kirje
            ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT check_aluskirje_vaiksem
        CHECK (aluskirje < liituv_kirje)
);

COMMENT ON TABLE paar IS 'Mestimiskandidaadid.';

CREATE TABLE IF NOT EXISTS public.kasutaja
(
    kasutaja_id  serial,
    kasutajanimi varchar(255) NOT NULL,
    CONSTRAINT kasutaja_pk
        PRIMARY KEY (kasutaja_id),
    CONSTRAINT kasutaja_kasutajanimi_ak
        UNIQUE (kasutajanimi)
);

COMMENT ON TABLE public.kasutaja IS 'IRS kasutajad.';
COMMENT ON COLUMN public.kasutaja.kasutajanimi IS 'IRS kasutajanime pikkus on kuni 255 tähemärki.';


CREATE TABLE IF NOT EXISTS public.tegevusetyyp
(
    tegevusetyyp_id smallint    NOT NULL,
    nimi            varchar(64) NOT NULL,
    CONSTRAINT tegevusetyyp_pk
        PRIMARY KEY (tegevusetyyp_id),
    CONSTRAINT tegevusetyyp_nimi_ak
        UNIQUE (nimi)
);

COMMENT ON TABLE public.tegevusetyyp IS 'Tegevuse tüüp.';

CREATE TABLE IF NOT EXISTS public.vastuolu
(
    vastuolu_id serial,
    reegel_id   smallint NOT NULL,
    paar_id     integer  NOT NULL,
    info        jsonb    NOT NULL,
    CONSTRAINT vastuolu_pk
        PRIMARY KEY (vastuolu_id),
    CONSTRAINT vastuolu_reegel_paar_ak
        UNIQUE (reegel_id, paar_id),
    CONSTRAINT vastuolu_reegel_reegel_id_fk
        FOREIGN KEY (reegel_id) REFERENCES public.reegel
            ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT vastuolu_paar_paar_id_fk
        FOREIGN KEY (paar_id) REFERENCES public.paar
            ON UPDATE RESTRICT ON DELETE CASCADE
);

COMMENT ON TABLE public.vastuolu IS 'Kirjepaaride vastuolud mestimisreeglitega.';

CREATE TABLE IF NOT EXISTS public.tegevus
(
    tegevuse_id     serial,
    paar_id         integer                               NOT NULL,
    tegevusetyyp_id smallint                              NOT NULL,
    kasutaja_id     integer                               NOT NULL,
    toimumisaeg     timestamptz DEFAULT CURRENT_TIMESTAMP NOT NULL,
    kommentaar      text                                  NOT NULL,
    CONSTRAINT tegevus_pk
        PRIMARY KEY (tegevuse_id),
    CONSTRAINT tegevus_ak
        UNIQUE (paar_id, tegevusetyyp_id, kasutaja_id, toimumisaeg),
    CONSTRAINT tegevus_paar_paar_id_fk
        FOREIGN KEY (paar_id) REFERENCES public.paar
            ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tegevus_kasutaja_kasutaja_id_fk
        FOREIGN KEY (kasutaja_id) REFERENCES public.kasutaja
            ON UPDATE RESTRICT ON DELETE RESTRICT,
    CONSTRAINT tegevus_tegevusetyyp_tegevusetyyp_id_fk
        FOREIGN KEY (tegevusetyyp_id) REFERENCES public.tegevusetyyp
            ON UPDATE RESTRICT ON DELETE RESTRICT
);

COMMENT ON TABLE public.tegevus IS 'Kasutajate süsteemis sooritatud toimingute logi.';

-- end::tabelid[]
-- tag::vaated[]

CREATE VIEW v_tegevused AS
SELECT p.paar_id,
       p.aluskirje,
       p.liituv_kirje,
       ARRAY_AGG(DISTINCT t.tegevusetyyp_id)                                              AS sooritatud_tegevused,
       ARRAY_AGG(DISTINCT t.tegevusetyyp_id) FILTER ( WHERE t.tegevusetyyp_id IN (1, 2) ) AS kas_mestida
FROM paar p
         LEFT JOIN tegevus t USING (paar_id)
GROUP BY p.paar_id;

CREATE MATERIALIZED VIEW mv_paarid AS
SELECT p.paar_id,
       p.aluskirje,
       p.liituv_kirje,
       p.sarnasus,
       p.ylekate,
       p.kaugus,
       COUNT(v.vastuolu_id)            AS vastuolude_arv,
       ARRAY_AGG(DISTINCT r.marc_vali) AS vastuoludega_valjad
FROM paar p
         JOIN vastuolu v USING (paar_id)
         JOIN reegel r USING (reegel_id)
GROUP BY p.paar_id;

-- end::vaated[]
-- tag::funktsioonid[]

-- Inspiratsiooniks kasutatud allikad:
-- https://www.postgresql.org/docs/current/queries-with.html#QUERIES-WITH-RECURSIVE
-- https://www.postgresql.org/docs/current/queries-table-expressions.html#QUERIES-LATERAL
-- https://stackoverflow.com/a/37382147/1245497

CREATE OR REPLACE FUNCTION f_seotud_kirjed(kirjenumber_in integer)
    RETURNS TABLE
            (
                kirjenumber integer
            )
    LANGUAGE sql
AS
$$
WITH RECURSIVE graph(num) AS
                   (SELECT ARRAY(SELECT DISTINCT liituv_kirje
                                 FROM paar
                                 WHERE aluskirje = kirjenumber_in)
                    UNION ALL
                    SELECT g.num || e1.p || e2.p
                    FROM graph g
                             LEFT JOIN LATERAL (
                        SELECT ARRAY(
                                       SELECT DISTINCT liituv_kirje
                                       FROM paar
                                       WHERE aluskirje = ANY (g.num)
                                         AND liituv_kirje <> ALL (g.num)
                                         AND liituv_kirje <> kirjenumber_in) AS p) e1 ON (TRUE)
                             LEFT JOIN LATERAL (
                        SELECT ARRAY(
                                       SELECT DISTINCT aluskirje
                                       FROM paar
                                       WHERE liituv_kirje = ANY (g.num)
                                         AND aluskirje <> ALL (g.num)
                                         AND aluskirje <> kirjenumber_in) AS p) e2 ON (TRUE)
                    WHERE e1.p <> '{}'
                       OR e2.p <> '{}')
SELECT DISTINCT UNNEST(num)
FROM graph
ORDER BY 1;
$$;

-- end::funktsioonid[]
-- tag::protseduurid[]

CREATE OR REPLACE PROCEDURE sp_lisa_vastuolu(
    aluskirje_in integer,
    liituv_kirje_in integer,
    marc_vali_in varchar(16),
    alamvali_in char(1),
    info_in jsonb,
    vastuolu_out OUT integer
)
    LANGUAGE plpgsql
AS
$$
DECLARE
    rid smallint;
    pid integer;
BEGIN
    SELECT paar_id INTO pid FROM paar p WHERE p.aluskirje = aluskirje_in AND p.liituv_kirje = liituv_kirje_in;
    SELECT reegel_id INTO rid FROM reegel r WHERE r.marc_vali = marc_vali_in AND r.alamvali = alamvali_in;

    INSERT INTO vastuolu(reegel_id, paar_id, info)
    VALUES (rid, pid, info_in)
    RETURNING vastuolu_id INTO vastuolu_out;
END
$$;

CREATE OR REPLACE PROCEDURE sp_logi_tegevus(
    aluskirje_in integer,
    liituv_kirje_in integer,
    kasutajanimi_in varchar(255),
    tegevuse_nimi_in varchar(64),
    kommentaar_in text,
    tegevus_out OUT integer
)
    LANGUAGE plpgsql
AS
$$
DECLARE
    pid  integer;
    kid  integer;
    ttid integer;
BEGIN
    SELECT paar_id INTO pid FROM paar p WHERE p.aluskirje = aluskirje_in AND p.liituv_kirje = liituv_kirje_in;
    SELECT kasutaja_id INTO kid FROM kasutaja k WHERE k.kasutajanimi = kasutajanimi_in;
    SELECT tegevusetyyp_id INTO ttid FROM tegevusetyyp tt WHERE tt.nimi = tegevuse_nimi_in;

    INSERT INTO tegevus(paar_id, tegevusetyyp_id, kasutaja_id, kommentaar)
    VALUES (pid, ttid, kid, kommentaar_in)
    RETURNING tegevuse_id INTO tegevus_out;
END
$$;

-- end::protseduurid[]

-- =====================================================================
-- GÉNÉRATION DU TERRITOIRE AGRICOLE FICTIF
-- Projet : territoire agricole fictif (génération de données de démo)
-- Version : v0 — 2026-10-15 (en cours d'écriture, étape par étape)
-- À exécuter APRÈS 01_tables.sql et l'import des tables brutes
-- =====================================================================
--
-- TABLES BRUTES (lues, jamais modifiées)
--   · parcellaire.rpg_import          : parcelles RPG 2025
--   · parcellaire.rpg_ilots_import    : îlots anonymes RPG 2025
--   · referentiel.communes_import     : communes Admin Express
--   · referentiel.cultures_rpg_import : nomenclature des codes cultures
--
-- PRINCIPE
--   Toute la génération se fait dans un schéma de travail (travail.*),
--   recréé à chaque exécution et consultable dans QGIS entre deux
--   étapes. Les tables finales (depots, exploitation, parcelles) ne
--   sont écrites qu'à la fin.
--   Seule une partie du territoire est attribuée aux exploitations
--   fictives (adhérents) : les autres îlots restent hors du jeu, ce
--   qui donne des parcellaires morcelés et réalistes.
--
-- TOUT EST ALÉATOIRE : chaque exécution donne un jeu différent.
--
-- ORDRE
--   0. Paramètres et schéma de travail
--   1. Chargement des îlots et des parcelles
--   2. Exploitations : surfaces cibles, attribution des îlots,
--      numérotation des îlots et des parcelles
--   3. Exploitations : noms et commune du siège
--   … (étapes suivantes à venir)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 0. PARAMÈTRES ET SCHÉMA DE TRAVAIL
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS travail AUTHORIZATION postgres;

DROP TABLE IF EXISTS travail.param;
CREATE TABLE travail.param AS
SELECT 25   AS nb_exploitations,
       20   AS surface_min,       -- ha
       240  AS surface_max,       -- ha
       112  AS surface_moy,       -- ha
       -- forme des parcellaires (étape 2c)
       2.0  AS hasard_distance,   -- distance × 1 à (1 + valeur) : 0 = blocs ronds
       0.15 AS part_satellites,   -- part des îlots pris à distance (0 à 1)
       750  AS satellite_min,     -- m, distance mini au parcellaire
       3000 AS satellite_max,     -- m, distance maxi au parcellaire
       4    AS nb_depots,
       2026 AS campagne;          -- culture N = RPG 2025 (décalage assumé)


-- ---------------------------------------------------------------------
-- 1a. ÎLOTS — îlots RPG qui portent au moins une parcelle importée
-- · MultiPolygon → plus grand polygone
-- · une parcelle dont l'îlot n'a pas été importé (bord d'emprise)
--   reçoit un îlot reconstitué par union de ses parcelles
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS travail.ilots;
CREATE TABLE travail.ilots (
	num_ilot_rpg text PRIMARY KEY,               -- identifiant RPG (texte dans le WFS)
	reconstitue  boolean NOT NULL DEFAULT false,
	surface      numeric(10,2),                 -- somme des parcelles (1b)
	num_expl     int4,                          -- étape 2
	num_ilot     int4,                          -- étape 2 (1 à n par exploitation)
	geom         public.geometry(geometry, 2154) NOT NULL
);

INSERT INTO travail.ilots (num_ilot_rpg, geom)
SELECT DISTINCT ON (i.num_ilot::text)
       i.num_ilot::text,
       g.geom
FROM parcellaire.rpg_ilots_import i
CROSS JOIN LATERAL (
  SELECT (d).geom
  FROM ST_Dump(i.geom) d
  ORDER BY ST_Area((d).geom) DESC
  LIMIT 1
) g
WHERE EXISTS (SELECT 1 FROM parcellaire.rpg_import r WHERE r.num_ilot::text = i.num_ilot::text)
ORDER BY i.num_ilot::text, ST_Area(g.geom) DESC;

INSERT INTO travail.ilots (num_ilot_rpg, reconstitue, geom)
SELECT r.num_ilot::text, true, ST_Union(r.geom)
FROM parcellaire.rpg_import r
WHERE NOT EXISTS (SELECT 1 FROM travail.ilots t WHERE t.num_ilot_rpg = r.num_ilot::text)
GROUP BY r.num_ilot::text;

CREATE INDEX ON travail.ilots USING gist (geom);


-- ---------------------------------------------------------------------
-- 1b. PARCELLES — table de travail, garde le lien avec le RPG
-- · MultiPolygon → plus grand polygone ; surface = ST_Area (ha)
-- · culture N : libellé de la nomenclature (code brut si absent)
-- · colonnes vides remplies aux étapes suivantes
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS travail.parcelles;
CREATE TABLE travail.parcelles AS
SELECT r.id                                         AS id_rpg,
       r.num_ilot::text                             AS num_ilot_rpg,
       r.code_cultu                                 AS code_n,
       coalesce(c.libelle_culture, r.code_cultu)    AS culture,
       r.cat_cult_p,
       round((ST_Area(g.geom) / 10000)::numeric, 2) AS surface,
       g.geom::public.geometry(polygon, 2154)       AS geom,
       NULL::text AS code_expl,      -- étape 2 (hérité de l'îlot)
       NULL::text AS num_ilot,       -- étape 2
       NULL::text AS num_parcelle,   -- étape 2
       NULL::text AS libelle,        -- étape 4
       NULL::text AS code_n1,        -- étape 5
       NULL::text AS code_n2,        -- étape 5
       NULL::text AS id_logiciel_interne   -- étape 6
FROM parcellaire.rpg_import r
CROSS JOIN LATERAL (
  SELECT (d).geom
  FROM ST_Dump(r.geom) d
  ORDER BY ST_Area((d).geom) DESC
  LIMIT 1
) g
LEFT JOIN referentiel.cultures_rpg_import c ON c.code_culture = r.code_cultu;

ALTER TABLE travail.parcelles ADD PRIMARY KEY (id_rpg);
CREATE INDEX ON travail.parcelles USING gist (geom);

-- Surface agricole de chaque îlot = somme de ses parcelles
UPDATE travail.ilots i
SET surface = s.surface
FROM (
  SELECT num_ilot_rpg, sum(surface) AS surface
  FROM travail.parcelles
  GROUP BY num_ilot_rpg
) s
WHERE s.num_ilot_rpg = i.num_ilot_rpg;


-- ---------------------------------------------------------------------
-- 2a. EXPLOITATIONS — code et surface cible
-- · code_expl : 'EXPL' + 5 chiffres tirés au hasard, sans doublon
-- · surface cible : loi triangulaire entre surface_min et surface_max,
--   de mode 3 × moy − min − max (soit 76 ha pour 20 / 240 / 112),
--   puis recalée pour que la moyenne tombe sur surface_moy
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS travail.exploitations;
CREATE TABLE travail.exploitations (
	num           int4 PRIMARY KEY,
	code_expl     text NOT NULL UNIQUE,
	surface_cible numeric(10,2) NOT NULL,
	surface       numeric(10,2) NOT NULL DEFAULT 0,
	complet       boolean NOT NULL DEFAULT false,
	graine        text,                         -- îlot de départ (2b)
	graine_geom   public.geometry(point, 2154)
);

WITH p AS (
  SELECT nb_exploitations AS n,
         surface_min::numeric AS a,
         surface_max::numeric AS b,
         (3 * surface_moy - surface_min - surface_max)::numeric AS c,
         surface_moy::numeric AS moy
  FROM travail.param
),
codes AS (
  SELECT 'EXPL' || lpad(x::text, 5, '0') AS code_expl,
         row_number() OVER () AS num
  FROM (
    SELECT x FROM generate_series(1, 99999) x
    ORDER BY random()
    LIMIT (SELECT n FROM p)
  ) t
),
tirage AS (
  SELECT c.num, c.code_expl, random()::numeric AS u   -- numeric : round(x, 2) n'existe pas en double precision
  FROM codes c
),
brut AS (
  SELECT t.num, t.code_expl,
         CASE WHEN t.u < (p.c - p.a) / (p.b - p.a)
              THEN p.a + sqrt(t.u * (p.b - p.a) * (p.c - p.a))
              ELSE p.b - sqrt((1 - t.u) * (p.b - p.a) * (p.b - p.c))
         END AS s
  FROM tirage t CROSS JOIN p
)
INSERT INTO travail.exploitations (num, code_expl, surface_cible)
SELECT b.num, b.code_expl,
       round(greatest(p.a, least(p.b, b.s * p.moy / avg(b.s) OVER ())), 2)
FROM brut b CROSS JOIN p;


-- ---------------------------------------------------------------------
-- 2b. GRAINES — un îlot de départ par exploitation, bien réparties
-- K-means sur les centres des îlots (k = nb_exploitations) ; la graine
-- est l'îlot le plus proche du centre de chaque groupe
-- ---------------------------------------------------------------------
WITH groupes AS (
  SELECT num_ilot_rpg,
         ST_PointOnSurface(geom) AS pt,
         ST_ClusterKMeans(ST_PointOnSurface(geom),
                          (SELECT nb_exploitations FROM travail.param)) OVER () + 1 AS k
  FROM travail.ilots
),
centres AS (
  SELECT k, ST_Centroid(ST_Collect(pt)) AS c
  FROM groupes
  GROUP BY k
),
graines AS (
  SELECT DISTINCT ON (g.k) g.k, g.num_ilot_rpg, g.pt
  FROM groupes g
  JOIN centres c USING (k)
  ORDER BY g.k, g.pt <-> c.c
)
UPDATE travail.exploitations e
SET graine = g.num_ilot_rpg,
    graine_geom = g.pt
FROM graines g
WHERE g.k = e.num;

-- La graine appartient à son exploitation
UPDATE travail.ilots i
SET num_expl = e.num
FROM travail.exploitations e
WHERE e.graine = i.num_ilot_rpg;

UPDATE travail.exploitations e
SET surface = i.surface
FROM travail.ilots i
WHERE i.num_ilot_rpg = e.graine;


-- ---------------------------------------------------------------------
-- 2c. CROISSANCE — chaque exploitation prend, tour à tour, un îlot libre
-- jusqu'à sa surface cible :
-- · en général : l'îlot le plus proche de son parcellaire ACTUEL (et non
--   de sa graine), distance × 1 à (1 + hasard_distance) au hasard
--   → croissance par le bord, formes allongées et irrégulières
-- · une fois sur part_satellites : un îlot pris au hasard entre
--   satellite_min et satellite_max du parcellaire (reprise, location)
--   → quelques îlots isolés, comme dans la réalité
-- Un îlot n'est pris que s'il fait moins dépasser la cible qu'il ne
-- manquerait sans lui (règle de la demi-surface).
-- ---------------------------------------------------------------------
DO $$
DECLARE
  p       record;
  e       record;
  possede public.geometry;
  v_id    text;
  v_surf  numeric;
BEGIN
  SELECT * INTO p FROM travail.param;

  LOOP
    EXIT WHEN NOT EXISTS (SELECT 1 FROM travail.exploitations WHERE NOT complet);

    FOR e IN
      SELECT * FROM travail.exploitations WHERE NOT complet ORDER BY random()
    LOOP
      SELECT ST_Collect(geom) INTO possede
      FROM travail.ilots
      WHERE num_expl = e.num;

      v_id := NULL;

      -- îlot satellite
      IF random() < p.part_satellites THEN
        SELECT i.num_ilot_rpg, i.surface INTO v_id, v_surf
        FROM travail.ilots i
        WHERE i.num_expl IS NULL
          AND e.surface + i.surface / 2 <= e.surface_cible
          AND ST_DWithin(i.geom, possede, p.satellite_max)
          AND NOT ST_DWithin(i.geom, possede, p.satellite_min)
        ORDER BY random()
        LIMIT 1;
      END IF;

      -- sinon, îlot voisin du parcellaire
      IF v_id IS NULL THEN
        SELECT i.num_ilot_rpg, i.surface INTO v_id, v_surf
        FROM travail.ilots i
        WHERE i.num_expl IS NULL
          AND ST_DWithin(i.geom, possede, p.satellite_max)
        ORDER BY ST_Distance(i.geom, possede) * (1 + random() * p.hasard_distance)
        LIMIT 1;
      END IF;

      IF v_id IS NULL OR e.surface + v_surf / 2 > e.surface_cible THEN
        UPDATE travail.exploitations SET complet = true WHERE num = e.num;
      ELSE
        UPDATE travail.ilots SET num_expl = e.num WHERE num_ilot_rpg = v_id;
        UPDATE travail.exploitations SET surface = surface + v_surf WHERE num = e.num;
      END IF;
    END LOOP;
  END LOOP;
END $$;


-- ---------------------------------------------------------------------
-- 2d. NUMÉROTATION
-- · îlots : 1 à n par exploitation, plus grand d'abord
-- · parcelles : héritent de l'exploitation et de l'îlot ;
--   num_parcelle 1 à n dans l'îlot, plus grande d'abord
-- · les parcelles des îlots non attribués gardent code_expl NULL :
--   elles ne seront pas écrites dans parcellaire.parcelles
-- ---------------------------------------------------------------------
WITH n AS (
  SELECT num_ilot_rpg,
         row_number() OVER (PARTITION BY num_expl ORDER BY surface DESC, num_ilot_rpg) AS num
  FROM travail.ilots
  WHERE num_expl IS NOT NULL
)
UPDATE travail.ilots i
SET num_ilot = n.num
FROM n
WHERE n.num_ilot_rpg = i.num_ilot_rpg;

UPDATE travail.parcelles p
SET code_expl = e.code_expl,
    num_ilot  = i.num_ilot::text
FROM travail.ilots i
JOIN travail.exploitations e ON e.num = i.num_expl
WHERE i.num_ilot_rpg = p.num_ilot_rpg;

WITH n AS (
  SELECT id_rpg,
         row_number() OVER (PARTITION BY code_expl, num_ilot ORDER BY surface DESC, id_rpg) AS num
  FROM travail.parcelles
  WHERE code_expl IS NOT NULL
)
UPDATE travail.parcelles p
SET num_parcelle = n.num::text
FROM n
WHERE n.id_rpg = p.id_rpg;


-- ---------------------------------------------------------------------
-- 3. EXPLOITATIONS — NOMS ET COMMUNE DU SIÈGE
-- Peut être relancée seule (sans refaire les étapes 0 à 2)
-- ---------------------------------------------------------------------
ALTER TABLE travail.exploitations
	ADD COLUMN IF NOT EXISTS libelle    text,
	ADD COLUMN IF NOT EXISTS commune    text,
	ADD COLUMN IF NOT EXISTS code_insee text;

UPDATE travail.exploitations SET libelle = NULL, commune = NULL, code_insee = NULL;


-- 3a. Noms maison, tirés en premier, sans doublon
WITH maison AS (
  SELECT nom, row_number() OVER (ORDER BY random()) AS rang
  FROM unnest(ARRAY[
    'EARL Du Faux', 'GAEC Chez Moi', 'SCEA Les 2 Rivières', 'EARL Les Oeufs Frais',
    'DOE Jane EI', 'DOE John EI', 'TOLKEN Danny EI', 'EARL Boucles de la Seine',
    'GAEC La Ferme', 'GAEC Hameau', 'EARL Vache à Lait'
  ]) AS nom
),
expl AS (
  SELECT num, row_number() OVER (ORDER BY random()) AS rang
  FROM travail.exploitations
)
UPDATE travail.exploitations e
SET libelle = m.nom
FROM expl x
JOIN maison m USING (rang)
WHERE e.num = x.num;


-- 3b. Générateur pour les exploitations restantes
-- · forme tirée : EARL 3 / GAEC 3 / SCEA 1 / EI 3
-- · EARL, GAEC, SCEA : lieu-dit BD TOPO le plus proche de l'îlot de
--   départ, non encore utilisé (« GAEC du Quesnay », « EARL de la
--   Sablonnière »)
-- · EI : NOM Prénom EI, sans doublon
DO $$
DECLARE
  e      record;
  forme  text;
  t      text;
  nom    text;
  utilises text[] := '{}';                   -- lieux-dits déjà pris
  noms   text[] := ARRAY['Lefebvre','Leroux','Duval','Lecomte','Hébert','Lemaire','Leclerc',
                         'Lebrun','Dupont','Marie','Lecoq','Delamare','Lemonnier','Leblond',
                         'Levasseur','Vasse','Lebas','Anquetil','Lecanu','Letellier','Hue',
                         'Picard','Lesueur','Fauvel','Legrand','Duboc','Lemercier','Bourdon',
                         'Morin','Hamel'];
  prenoms text[] := ARRAY['Pierre','Marie','Thomas','Julie','Nicolas','Sophie','Antoine',
                          'Camille','Julien','Émilie','Mathieu','Claire','Guillaume','Anne',
                          'Laurent','Céline','Sébastien','Aurélie','François','Hélène'];
BEGIN
  FOR e IN
    SELECT * FROM travail.exploitations WHERE libelle IS NULL ORDER BY random()
  LOOP
    forme := (ARRAY['EARL','EARL','EARL','GAEC','GAEC','GAEC','SCEA','EI','EI','EI'])
             [1 + floor(random() * 10)::int];

    IF forme <> 'EI' THEN
      -- lieu-dit le plus proche dont le nom n'est pas déjà pris
      SELECT l.toponyme INTO t
      FROM referentiel.lieux_dits_import l
      WHERE l.toponyme <> ALL (utilises)
      ORDER BY l.geom <-> e.graine_geom
      LIMIT 1;

      IF t IS NULL THEN
        forme := 'EI';                       -- plus de lieu-dit libre
      ELSE
        utilises := utilises || t;
        nom := forme || ' ' ||
          CASE
            WHEN t ILIKE 'le %'  THEN 'du '    || substr(t, 4)
            WHEN t ILIKE 'les %' THEN 'des '   || substr(t, 5)
            WHEN t ILIKE 'la %'  THEN 'de la ' || substr(t, 4)
            WHEN t ILIKE 'l''%'  THEN 'de l''' || substr(t, 3)
            WHEN lower(left(t, 1)) IN ('a','e','é','è','i','o','u','y','h')
                                 THEN 'd'''    || t
            ELSE                      'de '    || t
          END;
      END IF;
    END IF;

    IF forme = 'EI' THEN
      LOOP
        nom := upper(noms[1 + floor(random() * array_length(noms, 1))::int]) || ' ' ||
               prenoms[1 + floor(random() * array_length(prenoms, 1))::int] || ' EI';
        EXIT WHEN NOT EXISTS (SELECT 1 FROM travail.exploitations WHERE libelle = nom);
      END LOOP;
    END IF;

    UPDATE travail.exploitations SET libelle = nom WHERE num = e.num;
  END LOOP;
END $$;


-- 3c. Commune du siège : commune où l'exploitation a la plus grande
-- surface (point de chaque parcelle dans la commune)
WITH s AS (
  SELECT p.code_expl, c.code_insee, c.nom_officiel, sum(p.surface) AS ha
  FROM travail.parcelles p
  JOIN referentiel.communes_import c
    ON ST_Within(ST_PointOnSurface(p.geom), c.geom)
  WHERE p.code_expl IS NOT NULL
  GROUP BY p.code_expl, c.code_insee, c.nom_officiel
),
siege AS (
  SELECT DISTINCT ON (code_expl) *
  FROM s
  ORDER BY code_expl, ha DESC
)
UPDATE travail.exploitations e
SET commune    = s.nom_officiel,
    code_insee = s.code_insee
FROM siege s
WHERE s.code_expl = e.code_expl;


-- ---------------------------------------------------------------------
-- CONTRÔLES PROVISOIRES (iront dans 03_controles.sql)
-- À lancer un par un : l'éditeur Supabase n'affiche que le dernier
-- ---------------------------------------------------------------------

-- Étape 1 : chargement
SELECT (SELECT count(*) FROM parcellaire.rpg_import)                 AS parcelles_rpg,
       (SELECT count(*) FROM travail.parcelles)                      AS parcelles_travail,
       (SELECT count(*) FROM travail.ilots)                          AS ilots,
       (SELECT count(*) FROM travail.ilots WHERE reconstitue)        AS ilots_reconstitues,
       (SELECT count(*) FROM travail.parcelles
         WHERE culture = code_n)                                     AS cultures_sans_libelle,
       (SELECT round(sum(surface), 0) FROM travail.parcelles)        AS surface_ha;

-- Étape 2 : exploitations (cible / obtenue)
SELECT e.code_expl,
       e.surface_cible,
       e.surface,
       count(DISTINCT i.num_ilot_rpg) AS nb_ilots,
       (SELECT count(*) FROM travail.parcelles p WHERE p.code_expl = e.code_expl) AS nb_parcelles
FROM travail.exploitations e
LEFT JOIN travail.ilots i ON i.num_expl = e.num
GROUP BY e.num, e.code_expl, e.surface_cible, e.surface
ORDER BY e.surface DESC;

-- Étape 2 : synthèse (min / moyenne / max, part du territoire)
SELECT count(*)                  AS nb_exploitations,
       round(min(surface), 0)    AS min_ha,
       round(avg(surface), 0)    AS moy_ha,
       round(max(surface), 0)    AS max_ha,
       round(sum(surface), 0)    AS total_ha,
       round(100 * sum(surface) / (SELECT sum(surface) FROM travail.parcelles), 0) AS pct_territoire
FROM travail.exploitations;

-- Étape 3 : noms et siège (doublons_libelle doit valoir 0)
SELECT e.code_expl, e.libelle, e.commune, e.code_insee, e.surface,
       count(*) OVER (PARTITION BY e.libelle) - 1 AS doublons_libelle
FROM travail.exploitations e
ORDER BY e.libelle;
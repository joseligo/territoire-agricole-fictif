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
--
-- TOUT EST ALÉATOIRE : chaque exécution donne un jeu différent.
--
-- ORDRE
--   0. Paramètres et schéma de travail
--   1. Chargement des îlots et des parcelles
--   … (étapes suivantes à venir)
-- =====================================================================


- ---------------------------------------------------------------------
-- 0. PARAMÈTRES ET SCHÉMA DE TRAVAIL
-- ---------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS travail AUTHORIZATION postgres;
 
DROP TABLE IF EXISTS travail.param;
CREATE TABLE travail.param AS
SELECT 12   AS nb_exploitations,
       4    AS nb_depots,
       2026 AS campagne;   -- culture N = RPG 2025 (décalage assumé)
 
 
-- ---------------------------------------------------------------------
-- 1a. ÎLOTS — îlots RPG qui portent au moins une parcelle importée
-- · MultiPolygon → plus grand polygone
-- · une parcelle dont l'îlot n'a pas été importé (bord d'emprise)
--   reçoit un îlot reconstitué par union de ses parcelles
-- ---------------------------------------------------------------------
DROP TABLE IF EXISTS travail.ilots;
CREATE TABLE travail.ilots (
	num_ilot_rpg int8 PRIMARY KEY,
	reconstitue  boolean NOT NULL DEFAULT false,
	code_expl    text,                          -- étape 2
	num_ilot     int4,                          -- étape 2 (1 à n par exploitation)
	geom         public.geometry(geometry, 2154) NOT NULL
);
 
INSERT INTO travail.ilots (num_ilot_rpg, geom)
SELECT DISTINCT ON (i.num_ilot)
       i.num_ilot,
       g.geom
FROM parcellaire.rpg_ilots_import i
CROSS JOIN LATERAL (
  SELECT (d).geom
  FROM ST_Dump(i.geom) d
  ORDER BY ST_Area((d).geom) DESC
  LIMIT 1
) g
WHERE EXISTS (SELECT 1 FROM parcellaire.rpg_import r WHERE r.num_ilot = i.num_ilot)
ORDER BY i.num_ilot, ST_Area(g.geom) DESC;
 
INSERT INTO travail.ilots (num_ilot_rpg, reconstitue, geom)
SELECT r.num_ilot, true, ST_Union(r.geom)
FROM parcellaire.rpg_import r
WHERE NOT EXISTS (SELECT 1 FROM travail.ilots t WHERE t.num_ilot_rpg = r.num_ilot)
GROUP BY r.num_ilot;
 
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
       r.num_ilot::int8                             AS num_ilot_rpg,
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
 
 
-- ---------------------------------------------------------------------
-- CONTRÔLE DE L'ÉTAPE 1 (provisoire, ira dans 03_controles.sql)
-- ---------------------------------------------------------------------
SELECT (SELECT count(*) FROM parcellaire.rpg_import)                 AS parcelles_rpg,
       (SELECT count(*) FROM travail.parcelles)                      AS parcelles_travail,
       (SELECT count(*) FROM travail.ilots)                          AS ilots,
       (SELECT count(*) FROM travail.ilots WHERE reconstitue)        AS ilots_reconstitues,
       (SELECT count(*) FROM travail.parcelles
         WHERE culture = code_n)                                     AS cultures_sans_libelle,
       (SELECT round(sum(surface), 0) FROM travail.parcelles)        AS surface_ha;
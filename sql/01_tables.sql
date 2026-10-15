-- =====================================================================
-- DDL — TABLES
-- Projet : territoire agricole fictif (génération de données de démo)
-- Version : v2 — 2026-10-15 (structure validée)
-- À exécuter AVANT 02_generation.sql
-- =====================================================================
--
-- PRINCIPE
--   Socle minimal de trois tables : dépôts, exploitations, parcelles.
--   Le script de génération ne fait que des INSERT et des UPDATE sur
--   ces colonnes : il peut aussi tourner sur une base qui reprend ces
--   schémas, tables et noms de colonnes et y ajoute d'autres
--   colonnes, à condition qu'elles soient facultatives.
--
-- PRÉREQUIS
--   PostGIS dans public (QGIS génère du SQL non préfixé) :
--     CREATE EXTENSION IF NOT EXISTS postgis SCHEMA public;
--
-- HORS DDL — tables brutes importées depuis QGIS (WFS Géoplateforme,
-- emprise courante, EPSG:2154, géométries simples), avec leurs
-- attributs d'origine. Elles ne sont que lues par le script.
--   · parcellaire.rpg_import      : RPG 2025, parcelles graphiques
--   · referentiel.communes_import : communes Admin Express
--
-- PARAMÈTRES (en tête de 02_generation.sql)
--   CREATE TEMP TABLE param AS
--   SELECT 12 AS nb_exploitations, 4 AS nb_depots, 2026 AS campagne;
--   · la culture « N » de la campagne 2026 est celle déclarée au
--     RPG 2025 (décalage d'un an assumé, signalé dans le README)
--
-- CONVENTIONS
--   · Clés primaires uuid (gen_random_uuid())
--   · Liens entre tables par codes métier (code_expl, code_site)
--   · Géométries en Lambert-93 (SRID 2154)
--   · Valeurs en snake_case / minuscules
--   · RLS activé sans politique (bloque l'API REST Supabase, sans effet
--     sur la connexion PostgreSQL directe)
--   · Script rejouable (IF NOT EXISTS)
--
-- DÉPENDANCES : parcellaire → referentiel
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS referentiel AUTHORIZATION postgres;
CREATE SCHEMA IF NOT EXISTS parcellaire AUTHORIZATION postgres;


-- ---------------------------------------------------------------------
-- referentiel.depots — sites physiques (générés par le script)
-- · code_site : 'SITE' + 3 chiffres (SITE001…)
-- · geom      : K-means sur les centres des exploitations
--               (k = nb_depots)
-- · insee / commune : jointure spatiale avec communes_import
-- · un seul dépôt par commune (garanti par le script, vérifié dans
--   03_controles.sql)
-- · nom_site  : 'Site ' || commune
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS referentiel.depots (
	id         uuid        DEFAULT gen_random_uuid() NOT NULL,
	code_site  text        NOT NULL,
	nom_site   text        NOT NULL,
	insee      text        NOT NULL,
	commune    text        NOT NULL,
	geom       public.geometry(point, 2154) NULL,
	created_at timestamptz DEFAULT now() NOT NULL,
	CONSTRAINT depots_pkey PRIMARY KEY (id)
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_depots_code_site ON referentiel.depots USING btree (code_site);
CREATE INDEX IF NOT EXISTS idx_depots_geom ON referentiel.depots USING gist (geom);
ALTER TABLE referentiel.depots ENABLE ROW LEVEL SECURITY;


-- ---------------------------------------------------------------------
-- referentiel.exploitation — exploitations fictives (générées)
-- · code_expl : 'EXPL' + 5 chiffres tirés au hasard, sans doublon
-- · libelle_exploitation : liste maison tirée en premier, sans
--   doublon ; générateur (EARL / GAEC / SCEA / EI + nom) au-delà
-- · commune / code_insee : commune où l'exploitation a la plus
--   grande surface de parcelles (communes_import)
--   NB : code_insee ici, insee dans depots (noms conservés tels quels)
-- · depot : dépôt le plus proche du centre du parcellaire
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS referentiel.exploitation (
	id                   uuid        DEFAULT gen_random_uuid() NOT NULL,
	code_expl            text        NOT NULL,
	libelle_exploitation text        NOT NULL,
	commune              text        NULL,
	code_insee           text        NULL,
	depot                text        NULL,
	created_at           timestamptz DEFAULT now() NOT NULL,
	CONSTRAINT exploitation_pkey PRIMARY KEY (id),
	CONSTRAINT exploitation_depot_fkey FOREIGN KEY (depot) REFERENCES referentiel.depots(code_site) ON DELETE SET NULL
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_exploitation_code_expl ON referentiel.exploitation USING btree (code_expl);
ALTER TABLE referentiel.exploitation ENABLE ROW LEVEL SECURITY;


-- ---------------------------------------------------------------------
-- parcellaire.parcelles — parcelles de la campagne (générées)
-- · Remplie par le script à partir de parcellaire.rpg_import
-- · geom facultative (une parcelle peut ne pas être cartographiée ;
--   toujours renseignée par le script)
-- · num_ilot     : ST_ClusterDBSCAN par exploitation
-- · num_parcelle : 1 à n dans l'îlot, plus grande parcelle d'abord
-- · libelle      : lieu-dit où se trouve la parcelle, utilisé une
--   seule fois par exploitation (plus grande parcelle) ; les autres
--   parcelles reçoivent un nom généré (série 1 + complément série 2
--   une fois sur deux), sans doublon dans l'exploitation
-- · culture      : culture déclarée au RPG ; culture_n1 / culture_n2
--   tirées d'une rotation qui la contient (libellés)
-- · id_logiciel_interne : identifiant fictif d'un logiciel de suivi
--   parcellaire, unique PAR CAMPAGNE
-- · source_origine : 'logiciel' pour le jeu fictif
-- · Toutes les mises à jour du script filtrent sur la campagne de
--   param (la table peut contenir plusieurs campagnes)
-- ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS parcellaire.parcelles (
	id                  uuid          DEFAULT gen_random_uuid() NOT NULL,
	code_expl           text          NULL,
	campagne            int4          NOT NULL,
	num_ilot            text          NULL,
	num_parcelle        text          NULL,
	libelle             text          NULL,
	surface             numeric(10,2) NULL,
	culture             text          NULL,
	culture_n1          text          NULL,
	culture_n2          text          NULL,
	geom                public.geometry(polygon, 2154) NULL,
	id_logiciel_interne text          NULL,
	source_origine      text          NULL,
	created_at          timestamptz   DEFAULT now() NOT NULL,
	CONSTRAINT parcelles_pkey PRIMARY KEY (id),
	CONSTRAINT parcelles_code_expl_fkey FOREIGN KEY (code_expl) REFERENCES referentiel.exploitation(code_expl) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_parcelles_geom ON parcellaire.parcelles USING gist (geom);
CREATE UNIQUE INDEX IF NOT EXISTS idx_parcelles_campagne_id_logiciel
	ON parcellaire.parcelles USING btree (campagne, id_logiciel_interne)
	WHERE (id_logiciel_interne IS NOT NULL);
ALTER TABLE parcellaire.parcelles ENABLE ROW LEVEL SECURITY;

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
--   4. Libellés des parcelles (lieux-dits BD TOPO + générateur)
--   5. Cultures N-1 / N-2 (rotations)
--   6. Identifiants du logiciel de suivi parcellaire
--   7. Dépôts et rattachement des exploitations
--   8. Écriture dans les tables finales
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
       -- libellés des parcelles (étape 4)
       500  AS rayon_lieu_dit,    -- m, distance maxi parcelle → lieu-dit
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
-- 4. LIBELLÉS DES PARCELLES
-- Peut être relancée seule (sans refaire les étapes 0 à 3)
-- · 4a : lieu-dit BD TOPO le plus proche (rayon_lieu_dit), utilisé une
--   seule fois par exploitation → parcelle la plus proche du point
-- · 4b : les autres parcelles reçoivent un nom généré à partir de deux
--   séries (lieu-dit type + complément une fois sur deux), sans
--   doublon dans l'exploitation
-- ---------------------------------------------------------------------
ALTER TABLE travail.param
	ADD COLUMN IF NOT EXISTS rayon_lieu_dit int DEFAULT 500;   -- si param date d'avant l'étape 4
ALTER TABLE travail.parcelles
	ADD COLUMN IF NOT EXISTS source_libelle text;               -- 'lieu_dit' / 'genere'

UPDATE travail.parcelles SET libelle = NULL, source_libelle = NULL;


-- 4a. Lieux-dits réels (première lettre en majuscule : « le Quesnay » → « Le Quesnay »)
WITH proche AS (
  SELECT p.id_rpg, p.code_expl, l.toponyme, l.dist
  FROM travail.parcelles p
  CROSS JOIN LATERAL (
    SELECT ld.toponyme, ST_Distance(ld.geom, p.geom) AS dist
    FROM referentiel.lieux_dits_import ld
    WHERE ST_DWithin(ld.geom, p.geom, (SELECT rayon_lieu_dit FROM travail.param))
    ORDER BY ld.geom <-> p.geom
    LIMIT 1
  ) l
  WHERE p.code_expl IS NOT NULL
),
choix AS (
  SELECT DISTINCT ON (code_expl, toponyme) id_rpg, toponyme
  FROM proche
  ORDER BY code_expl, toponyme, dist, id_rpg
)
UPDATE travail.parcelles p
SET libelle        = upper(left(c.toponyme, 1)) || substr(c.toponyme, 2),
    source_libelle = 'lieu_dit'
FROM choix c
WHERE c.id_rpg = p.id_rpg;


-- 4b. Noms générés (séries reprises du jeu de démo d'origine)
-- · 50 % de noms simples, 50 % avec complément (tirage pondéré)
-- · aucun nom déjà présent dans l'exploitation
WITH serie1 AS (
  SELECT unnest(ARRAY[
    'La Noue','Les Ouches','La Lande','Le Pré Long','La Grande Pièce','Les Grandes Pièces',
    'Le Champ Rond','La Croix','La Butte','Le Fief','Les Fiefs','La Bossardière','La Rivière',
    'Le Marais','La Prée','Les Prés','Le Bois','La Garenne','La Mare','Les Terres Rouges',
    'La Vigne','Les Vignes','Le Clos','Le Grand Clos','La Pâture','Les Pâtis','La Gâtine',
    'Le Chêne','Les Chaumes','La Fosse','Le Moulin','La Métairie','La Borderie','La Coudre',
    'L''Ouche','La Touche','La Cour','Le Puits','La Plaine','Les Rochettes','La Brosse',
    'Le Plessis','La Vallée','Le Coteau','La Pièce Neuve','Le Champ Long','La Haie',
    'Les Landes','La Barre','Le Pas']) AS s1
),
serie2 AS (
  SELECT unnest(ARRAY[
    'du Moulin','du Bourg','de la Croix','du Chêne','de la Mare','du Bois',
    'de la Route','du Haut','du Bas','Nord','Sud','de l''Étang','des Saules',
    'du Puits','de la Gare','du Calvaire','de la Fontaine','des Peupliers',
    'de la Lande','du Château','des Noyers','de l''Église','de la Ferme',
    'du Ruisseau','des Ormeaux']) AS s2
),
combos AS (
  SELECT s1 AS nom, 0.5 / 50 AS poids FROM serie1
  UNION ALL
  SELECT s1 || ' ' || s2, 0.5 / 1250 FROM serie1 CROSS JOIN serie2
),
a_nommer AS (
  SELECT id_rpg, code_expl,
         row_number() OVER (PARTITION BY code_expl ORDER BY random()) AS rang
  FROM travail.parcelles
  WHERE code_expl IS NOT NULL
    AND libelle IS NULL
),
tirage AS (
  SELECT e.code_expl, c.nom,
         row_number() OVER (PARTITION BY e.code_expl
                            ORDER BY ln(1 - random()) / c.poids DESC) AS rang
  FROM (SELECT DISTINCT code_expl FROM a_nommer) e
  CROSS JOIN combos c
  WHERE NOT EXISTS (
    SELECT 1 FROM travail.parcelles p
    WHERE p.code_expl = e.code_expl
      AND p.libelle = c.nom
  )
)
UPDATE travail.parcelles p
SET libelle        = t.nom,
    source_libelle = 'genere'
FROM a_nommer a
JOIN tirage t USING (code_expl, rang)
WHERE p.id_rpg = a.id_rpg;


-- ---------------------------------------------------------------------
-- 5. CULTURES N-1 / N-2 — rotations
-- Peut être relancée seule (sans refaire les étapes 0 à 4)
-- · culture N = culture déclarée au RPG (code_n)
-- · le script cherche toutes les positions du code N dans les
--   rotations, en tire une (pondérée par le poids de la rotation) ;
--   N-1 et N-2 = cases précédentes du cycle
-- · un code absent de toutes les rotations (prairie permanente,
--   verger, bordure, jachère…) est reconduit : N-1 = N-2 = N
-- ---------------------------------------------------------------------

-- 5a. Table des rotations (codes RPG, dans l'ordre des années)
-- · poids = surface estimée de la rotation sur le territoire (ha),
--   déduite de la surface N de sa culture de tête ÷ sa fréquence dans
--   le cycle (ex. pomme de terre 47 ha × 6 ans ≈ 280 ha). À ajuster
--   pour un autre territoire.
-- · une année d'une rotation pèse poids ÷ longueur du cycle : une
--   parcelle en blé ne « remonte » vers une rotation rare (carottes,
--   moutarde…) qu'en proportion de la place réelle de cette rotation.
-- · les rotations qui partagent une case (luzerne / trèfle…) sont
--   dupliquées.
DROP TABLE IF EXISTS travail.rotations;
CREATE TABLE travail.rotations (
	rotation int PRIMARY KEY,
	systeme  text    NOT NULL,
	poids    numeric NOT NULL,     -- ha estimés
	cycle    text[]  NOT NULL
);

INSERT INTO travail.rotations VALUES
	( 1, 'Caux classique',                 1400, ARRAY['LIF','BTH','CZH','BTH']),
	( 2, 'Lin / betterave',                 230, ARRAY['BTN','BTH','LIF','BTH']),
	( 3, 'Pomme de terre',                  280, ARRAY['PTC','BTH','LIF','BTH','CZH','BTH']),
	( 4, 'Maïs / blé (élevage)',            700, ARRAY['MIS','MIS','BTH','ORH']),
	( 5, 'Prairie temporaire',               75, ARRAY['PTR','PTR','PTR','MIS','BTH']),
	( 6, 'Luzerne',                           3, ARRAY['LUZ','LUZ','LUZ','MIS','BTH']),
	( 7, 'Trèfle',                           40, ARRAY['TRE','TRE','TRE','MIS','BTH']),
	( 8, 'Mélange légumineuses-graminées',   57, ARRAY['MLG','MLG','MLG','MIS','BTH']),
	( 9, 'Mélange multi-espèces',             8, ARRAY['MLC','MLC','MLC','MIS','BTH']),
	(10, 'Pois de printemps',               115, ARRAY['PPR','BTH','CZH','BTH','ORP']),
	(11, 'Féverole de printemps',            25, ARRAY['FVP','BTH','CZH','BTH','ORP']),
	(12, 'Féverole d''hiver',                72, ARRAY['FVL','BTH','CZH','BTH']),
	(13, 'Tournesol',                        56, ARRAY['TRN','BTH','CZH','BTH']),
	(14, 'Avoine de printemps',              12, ARRAY['AVP','BTH','LIF','BTH']),
	(15, 'Avoine d''hiver',                  12, ARRAY['AVH','BTH','LIF','BTH']),
	(16, 'Légumes de plein champ',            6, ARRAY['CAR','BTH','OIG','BTH','POR','ORP']),
	(17, 'Moutarde',                          3, ARRAY['MOT','BTH','ORH']);


-- 5b. Tirage de la position dans une rotation
ALTER TABLE travail.parcelles
	ADD COLUMN IF NOT EXISTS culture_n1 text,
	ADD COLUMN IF NOT EXISTS culture_n2 text,
	ADD COLUMN IF NOT EXISTS rotation   int;      -- NULL = culture reconduite

UPDATE travail.parcelles
SET code_n1 = NULL, code_n2 = NULL, culture_n1 = NULL, culture_n2 = NULL, rotation = NULL;

WITH positions AS (
  SELECT r.rotation, r.poids, r.cycle,
         array_length(r.cycle, 1) AS n,
         t.code, t.pos::int AS pos
  FROM travail.rotations r
  CROSS JOIN LATERAL unnest(r.cycle) WITH ORDINALITY AS t(code, pos)
),
tirage AS (
  SELECT DISTINCT ON (p.id_rpg)
         p.id_rpg, s.rotation, s.cycle, s.n, s.pos
  FROM travail.parcelles p
  JOIN positions s ON s.code = p.code_n
  WHERE p.code_expl IS NOT NULL
  ORDER BY p.id_rpg, ln(1 - random()) / (s.poids / s.n) DESC   -- poids d'une année du cycle
)
UPDATE travail.parcelles p
SET rotation = t.rotation,
    code_n1  = t.cycle[1 + (t.pos - 2 + t.n)     % t.n],
    code_n2  = t.cycle[1 + (t.pos - 3 + 2 * t.n) % t.n]
FROM tirage t
WHERE p.id_rpg = t.id_rpg;

-- 5c. Cultures hors rotation : reconduites à l'identique
UPDATE travail.parcelles
SET code_n1 = code_n,
    code_n2 = code_n
WHERE code_expl IS NOT NULL
  AND code_n1 IS NULL;

-- 5d. Libellés N-1 / N-2 (nomenclature, code brut si absent)
UPDATE travail.parcelles p
SET culture_n1 = coalesce(c1.libelle_culture, p.code_n1),
    culture_n2 = coalesce(c2.libelle_culture, p.code_n2)
FROM travail.parcelles q
LEFT JOIN referentiel.cultures_rpg_import c1 ON c1.code_culture = q.code_n1
LEFT JOIN referentiel.cultures_rpg_import c2 ON c2.code_culture = q.code_n2
WHERE q.id_rpg = p.id_rpg
  AND p.code_expl IS NOT NULL;


-- ---------------------------------------------------------------------
-- 6. ID_LOGICIEL_INTERNE — 'LOG' + 7 chiffres, à partir de 1048200,
-- petits trous dans la numérotation (saut de 1 à 4), ordre
-- exploitation / îlot / parcelle
-- Peut être relancée seule
-- ---------------------------------------------------------------------
UPDATE travail.parcelles SET id_logiciel_interne = NULL;

WITH pas AS (
  SELECT id_rpg, code_expl, num_ilot::int AS ilot, num_parcelle::int AS parc,
         1 + floor(random() * 4)::int AS saut
  FROM travail.parcelles
  WHERE code_expl IS NOT NULL
),
numeros AS (
  SELECT id_rpg,
         1048200 + sum(saut) OVER (ORDER BY code_expl, ilot, parc, id_rpg) AS n
  FROM pas
)
UPDATE travail.parcelles p
SET id_logiciel_interne = 'LOG' || lpad(n.n::text, 7, '0')
FROM numeros n
WHERE p.id_rpg = n.id_rpg;


-- ---------------------------------------------------------------------
-- 7. DÉPÔTS — sites physiques, puis rattachement des exploitations
-- Peut être relancée seule
-- · 7a : K-means sur les centres des parcellaires (k = nb_depots) ; le
--   dépôt est posé au centre de chaque groupe, dans sa commune réelle
-- · un seul dépôt par commune : si la commune est déjà prise, le dépôt
--   passe dans la commune libre la plus proche (point posé dans
--   celle-ci)
-- · code_site 'SITE' + 3 chiffres (le groupe le plus gros d'abord),
--   nom_site 'Site ' || commune
-- · 7b : chaque exploitation est rattachée au dépôt le plus proche du
--   centre de son parcellaire
-- ---------------------------------------------------------------------
ALTER TABLE travail.exploitations
	ADD COLUMN IF NOT EXISTS centre public.geometry(point, 2154),
	ADD COLUMN IF NOT EXISTS depot  text;

UPDATE travail.exploitations e
SET centre = c.geom
FROM (
  SELECT num_expl, ST_Centroid(ST_Collect(geom)) AS geom
  FROM travail.ilots
  WHERE num_expl IS NOT NULL
  GROUP BY num_expl
) c
WHERE c.num_expl = e.num;

DROP TABLE IF EXISTS travail.depots;
CREATE TABLE travail.depots (
	code_site text PRIMARY KEY,
	nom_site  text NOT NULL,
	insee     text NOT NULL,
	commune   text NOT NULL,
	nb_expl   int,
	geom      public.geometry(point, 2154) NOT NULL
);

-- 7a. Position et commune des dépôts
DO $$
DECLARE
  g      record;
  c      record;
  rang   int := 0;
  pris   text[] := '{}';               -- communes déjà dotées d'un dépôt
BEGIN
  FOR g IN
    WITH groupes AS (
      SELECT centre,
             ST_ClusterKMeans(centre, (SELECT nb_depots FROM travail.param)) OVER () AS k
      FROM travail.exploitations
    )
    SELECT k, count(*) AS nb, ST_Centroid(ST_Collect(centre)) AS pt
    FROM groupes
    GROUP BY k
    ORDER BY count(*) DESC, k
  LOOP
    rang := rang + 1;

    -- commune qui contient le centre du groupe, sinon la plus proche ;
    -- toujours parmi les communes encore libres
    SELECT ci.code_insee, ci.nom_officiel, ci.geom,
           ST_Contains(ci.geom, g.pt) AS contient
    INTO c
    FROM referentiel.communes_import ci
    WHERE ci.code_insee <> ALL (pris)
    ORDER BY ST_Contains(ci.geom, g.pt) DESC, ci.geom <-> g.pt
    LIMIT 1;

    pris := pris || c.code_insee;

    INSERT INTO travail.depots (code_site, nom_site, insee, commune, nb_expl, geom)
    VALUES ('SITE' || lpad(rang::text, 3, '0'),
            'Site ' || c.nom_officiel,
            c.code_insee,
            c.nom_officiel,
            g.nb,
            CASE WHEN c.contient THEN g.pt ELSE ST_PointOnSurface(c.geom) END);
  END LOOP;
END $$;

-- 7b. Dépôt le plus proche du centre de chaque parcellaire
UPDATE travail.exploitations e
SET depot = (
  SELECT d.code_site
  FROM travail.depots d
  ORDER BY d.geom <-> e.centre
  LIMIT 1
);


-- ---------------------------------------------------------------------
-- 8. ÉCRITURE DANS LES TABLES FINALES
-- À lancer quand le résultat du schéma travail est validé.
-- · parcellaire.parcelles : la campagne de param est remplacée ; les
--   autres campagnes ne sont pas touchées
-- · exploitations et dépôts devenus orphelins (plus aucune parcelle ou
--   exploitation) sont supprimés, puis les nouveaux insérés ou mis à
--   jour (ON CONFLICT sur les codes)
-- · si d'autres tables référencent ces lignes, une suppression peut
--   être refusée par leurs clés étrangères : rien n'est alors écrit
--   (transaction)
-- ---------------------------------------------------------------------
BEGIN;

DELETE FROM parcellaire.parcelles
WHERE campagne = (SELECT campagne FROM travail.param);

DELETE FROM referentiel.exploitation e
WHERE NOT EXISTS (SELECT 1 FROM parcellaire.parcelles p WHERE p.code_expl = e.code_expl)
  AND NOT EXISTS (SELECT 1 FROM travail.exploitations t WHERE t.code_expl = e.code_expl);

DELETE FROM referentiel.depots d
WHERE NOT EXISTS (SELECT 1 FROM referentiel.exploitation e WHERE e.depot = d.code_site)
  AND NOT EXISTS (SELECT 1 FROM travail.depots t WHERE t.code_site = d.code_site);

INSERT INTO referentiel.depots (code_site, nom_site, insee, commune, geom)
SELECT code_site, nom_site, insee, commune, geom
FROM travail.depots
ON CONFLICT (code_site) DO UPDATE
SET nom_site = EXCLUDED.nom_site,
    insee    = EXCLUDED.insee,
    commune  = EXCLUDED.commune,
    geom     = EXCLUDED.geom;

INSERT INTO referentiel.exploitation (code_expl, libelle_exploitation, commune, code_insee, depot)
SELECT code_expl, libelle, commune, code_insee, depot
FROM travail.exploitations
ON CONFLICT (code_expl) DO UPDATE
SET libelle_exploitation = EXCLUDED.libelle_exploitation,
    commune              = EXCLUDED.commune,
    code_insee           = EXCLUDED.code_insee,
    depot                = EXCLUDED.depot;

INSERT INTO parcellaire.parcelles
  (code_expl, campagne, num_ilot, num_parcelle, libelle, surface,
   culture, culture_n1, culture_n2, geom, id_logiciel_interne, source_origine)
SELECT p.code_expl, (SELECT campagne FROM travail.param), p.num_ilot, p.num_parcelle,
       p.libelle, p.surface, p.culture, p.culture_n1, p.culture_n2, p.geom,
       p.id_logiciel_interne, 'logiciel'
FROM travail.parcelles p
WHERE p.code_expl IS NOT NULL;

COMMIT;


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

-- Étape 4 : libellés par exploitation (sans_libelle et doublons doivent valoir 0)
SELECT code_expl,
       count(*)                                          AS nb_parcelles,
       count(*) FILTER (WHERE source_libelle = 'lieu_dit') AS lieux_dits,
       count(*) FILTER (WHERE source_libelle = 'genere')   AS generes,
       count(*) FILTER (WHERE libelle IS NULL)             AS sans_libelle,
       count(*) - count(DISTINCT libelle)                  AS doublons
FROM travail.parcelles
WHERE code_expl IS NOT NULL
GROUP BY code_expl
ORDER BY code_expl;

-- Étape 4 : échantillon de 20 parcelles
SELECT code_expl, num_ilot, num_parcelle, libelle, source_libelle, culture, surface
FROM travail.parcelles
WHERE code_expl IS NOT NULL
ORDER BY random()
LIMIT 20;

-- Étape 5 : assolement N / N-1 / N-2 (ha) — les trois colonnes doivent rester du même ordre de grandeur
WITH codes AS (
  SELECT code_n  AS code FROM travail.parcelles WHERE code_expl IS NOT NULL
  UNION
  SELECT code_n1 FROM travail.parcelles WHERE code_expl IS NOT NULL
  UNION
  SELECT code_n2 FROM travail.parcelles WHERE code_expl IS NOT NULL
)
SELECT c.code, coalesce(n.libelle_culture, c.code) AS culture,
       coalesce(round(sum(p.surface) FILTER (WHERE p.code_n  = c.code)), 0) AS ha_n,
       coalesce(round(sum(p.surface) FILTER (WHERE p.code_n1 = c.code)), 0) AS ha_n1,
       coalesce(round(sum(p.surface) FILTER (WHERE p.code_n2 = c.code)), 0) AS ha_n2
FROM codes c
CROSS JOIN travail.parcelles p
LEFT JOIN referentiel.cultures_rpg_import n ON n.code_culture = c.code
WHERE p.code_expl IS NOT NULL
GROUP BY c.code, n.libelle_culture
ORDER BY ha_n DESC;

-- Étape 5 : parcelles en rotation / reconduites, et vides (doit valoir 0)
SELECT count(*) FILTER (WHERE rotation IS NOT NULL) AS en_rotation,
       count(*) FILTER (WHERE rotation IS NULL)     AS reconduites,
       count(*) FILTER (WHERE code_n1 IS NULL OR code_n2 IS NULL
                           OR culture_n1 IS NULL OR culture_n2 IS NULL) AS vides
FROM travail.parcelles
WHERE code_expl IS NOT NULL;

-- Étape 6 : identifiants (nb = nb_distincts, aucun vide)
SELECT count(*) AS nb, count(DISTINCT id_logiciel_interne) AS nb_distincts,
       count(*) FILTER (WHERE id_logiciel_interne IS NULL) AS vides,
       min(id_logiciel_interne), max(id_logiciel_interne)
FROM travail.parcelles
WHERE code_expl IS NOT NULL;

-- Étape 7 : dépôts (un par commune, toutes les exploitations rattachées)
SELECT d.code_site, d.nom_site, d.insee,
       count(e.*)                      AS nb_exploitations,
       round(sum(e.surface))           AS ha,
       (SELECT count(*) FROM travail.depots) = (SELECT count(DISTINCT insee) FROM travail.depots) AS un_par_commune,
       (SELECT count(*) FROM travail.exploitations WHERE depot IS NULL) AS expl_sans_depot
FROM travail.depots d
LEFT JOIN travail.exploitations e ON e.depot = d.code_site
GROUP BY d.code_site, d.nom_site, d.insee
ORDER BY d.code_site;

-- Étape 8 : tables finales (comparer avec le schéma travail)
SELECT (SELECT count(*) FROM referentiel.depots)        AS depots,
       (SELECT count(*) FROM referentiel.exploitation)  AS exploitations,
       (SELECT count(*) FROM parcellaire.parcelles
         WHERE campagne = (SELECT campagne FROM travail.param)) AS parcelles,
       (SELECT round(sum(surface)) FROM parcellaire.parcelles
         WHERE campagne = (SELECT campagne FROM travail.param)) AS surface_ha,
       (SELECT count(*) FROM parcellaire.parcelles p
         WHERE NOT EXISTS (SELECT 1 FROM referentiel.exploitation e WHERE e.code_expl = p.code_expl)) AS parcelles_orphelines;
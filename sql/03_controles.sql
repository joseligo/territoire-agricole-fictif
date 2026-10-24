-- =====================================================================
-- CONTRÔLES DU TERRITOIRE AGRICOLE FICTIF
-- Projet : territoire agricole fictif (génération de données de démo)
-- Version : v1 — 2026-10-24
-- À exécuter APRÈS 02_generation.sql (étape 8 comprise)
-- Porte sur les tables finales ; campagne lue dans travail.param
--
-- À lancer un par un : l'éditeur Supabase n'affiche que le dernier
-- résultat. Les contrôles marqués (= 0) doivent renvoyer 0.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. SYNTHÈSE
-- ---------------------------------------------------------------------
SELECT (SELECT count(*) FROM referentiel.depots)        AS depots,
       (SELECT count(*) FROM referentiel.exploitation)  AS exploitations,
       count(*)                                         AS parcelles,
       count(DISTINCT code_expl || '-' || num_ilot)     AS ilots,
       round(sum(surface))                              AS surface_ha
FROM parcellaire.parcelles
WHERE campagne = (SELECT campagne FROM travail.param);


-- ---------------------------------------------------------------------
-- 2. EXPLOITATIONS — surface, îlots, parcelles, siège, dépôt
-- ---------------------------------------------------------------------
SELECT e.code_expl, e.libelle_exploitation, e.commune, e.depot,
       count(DISTINCT p.num_ilot) AS nb_ilots,
       count(p.*)                 AS nb_parcelles,
       round(sum(p.surface))      AS surface_ha
FROM referentiel.exploitation e
LEFT JOIN parcellaire.parcelles p
       ON p.code_expl = e.code_expl
      AND p.campagne  = (SELECT campagne FROM travail.param)
GROUP BY e.code_expl, e.libelle_exploitation, e.commune, e.depot
ORDER BY surface_ha DESC NULLS LAST;


-- ---------------------------------------------------------------------
-- 3. DÉPÔTS — un par commune, exploitations et surface rattachées
-- ---------------------------------------------------------------------
SELECT d.code_site, d.nom_site, d.insee,
       count(DISTINCT e.code_expl) AS nb_exploitations,
       round(sum(p.surface))       AS surface_ha
FROM referentiel.depots d
LEFT JOIN referentiel.exploitation e ON e.depot = d.code_site
LEFT JOIN parcellaire.parcelles p
       ON p.code_expl = e.code_expl
      AND p.campagne  = (SELECT campagne FROM travail.param)
GROUP BY d.code_site, d.nom_site, d.insee
ORDER BY d.code_site;

-- Un seul dépôt par commune (= 0)
SELECT count(*) - count(DISTINCT insee) AS depots_en_double
FROM referentiel.depots;


-- ---------------------------------------------------------------------
-- 4. ASSOLEMENT N / N-1 / N-2 (ha)
-- ---------------------------------------------------------------------
WITH p AS (
  SELECT * FROM parcellaire.parcelles
  WHERE campagne = (SELECT campagne FROM travail.param)
),
cultures AS (
  SELECT culture AS c FROM p
  UNION SELECT culture_n1 FROM p
  UNION SELECT culture_n2 FROM p
)
SELECT k.c AS culture,
       coalesce(round(sum(p.surface) FILTER (WHERE p.culture    = k.c)), 0) AS ha_n,
       coalesce(round(sum(p.surface) FILTER (WHERE p.culture_n1 = k.c)), 0) AS ha_n1,
       coalesce(round(sum(p.surface) FILTER (WHERE p.culture_n2 = k.c)), 0) AS ha_n2
FROM cultures k
CROSS JOIN p
GROUP BY k.c
ORDER BY ha_n DESC;


-- ---------------------------------------------------------------------
-- 5. COHÉRENCE (tous les compteurs = 0)
-- ---------------------------------------------------------------------
WITH p AS (
  SELECT * FROM parcellaire.parcelles
  WHERE campagne = (SELECT campagne FROM travail.param)
)
SELECT
  -- parcelles sans exploitation connue
  (SELECT count(*) FROM p
    WHERE NOT EXISTS (SELECT 1 FROM referentiel.exploitation e
                      WHERE e.code_expl = p.code_expl))               AS parcelles_orphelines,
  -- champs obligatoires du jeu de démo
  (SELECT count(*) FROM p
    WHERE geom IS NULL OR libelle IS NULL OR culture IS NULL
       OR culture_n1 IS NULL OR culture_n2 IS NULL
       OR num_ilot IS NULL OR num_parcelle IS NULL)                   AS champs_vides,
  -- identifiants logiciel en double
  (SELECT count(*) - count(DISTINCT id_logiciel_interne) FROM p)      AS id_logiciel_en_double,
  -- libellés en double dans une même exploitation
  (SELECT count(*) - count(DISTINCT code_expl || '|' || libelle) FROM p) AS libelles_en_double,
  -- numéro de parcelle en double dans un îlot
  (SELECT count(*) - count(DISTINCT code_expl || '|' || num_ilot || '|' || num_parcelle) FROM p)
                                                                      AS num_parcelle_en_double,
  -- surface stockée ≠ surface du polygone (tolérance 0,01 ha)
  (SELECT count(*) FROM p
    WHERE abs(surface - ST_Area(geom) / 10000) > 0.01)                AS surfaces_incoherentes,
  -- exploitations sans dépôt, sans siège
  (SELECT count(*) FROM referentiel.exploitation WHERE depot IS NULL)   AS expl_sans_depot,
  (SELECT count(*) FROM referentiel.exploitation WHERE commune IS NULL) AS expl_sans_commune,
  -- géométries invalides
  (SELECT count(*) FROM p WHERE NOT ST_IsValid(geom))                 AS geometries_invalides;


-- ---------------------------------------------------------------------
-- 6. ÉCHANTILLON (20 parcelles au hasard)
-- ---------------------------------------------------------------------
SELECT p.code_expl, e.libelle_exploitation, p.num_ilot, p.num_parcelle,
       p.libelle, p.surface, p.culture, p.culture_n1, p.culture_n2,
       p.id_logiciel_interne
FROM parcellaire.parcelles p
JOIN referentiel.exploitation e USING (code_expl)
WHERE p.campagne = (SELECT campagne FROM travail.param)
ORDER BY random()
LIMIT 20;
-- =====================================================================
-- JEU DE DONNÉES FICTIF — DÉMO / PORTFOLIO
-- Projet : prélèvements de sol (PostGIS Supabase / QGIS / QField)
-- Version : v1 — 2026-10-04
-- À exécuter APRÈS ddl_tables_261001.sql, ddl_fonctions_triggers_261001.sql
-- et ddl_vues_261003.sql
-- =====================================================================
--
-- PRÉREQUIS (manuels, avant ce script)
--   1. Parcelles : RPG anonyme récupéré en WFS (Géoplateforme IGN,
--      https://data.geopf.fr/wfs/ows, couche RPG.xxxx:parcelles_graphiques,
--      option « emprise courante ») puis copié dans parcellaire.parcelles.
--      Seule la géométrie est reprise (noms de champs différents) ;
--      campagne doit être renseignée (NOT NULL).
--      Source à citer : IGN / ASP – RPG anonyme, Licence Ouverte Etalab 2.0
--   2. referentiel.exploitation : 12 exploitations fictives (code EXPLxxxxx)
--   3. referentiel.depots : 4 dépôts avec un point
--
-- TOUT EST ALÉATOIRE : chaque exécution donne un jeu différent.
-- Pour une démo stable, exécuter une seule fois.
--
-- ORDRE
--   1. Surface + source_origine        6. id_logiciel_interne
--   2. Exploitations (K-means)         7. Dépôt des exploitations
--   3. Îlots (parcelles qui se         8. Commandes (import logiciel)
--      touchent, par exploitation)     9. Mode de prélèvement 55 / 45
--   4. Libellés (lieux-dits)          10. Prélèvements (20 à 40 % par dépôt)
--   5. Cultures N, N-1, N-2           11. Contrôles
--      (rotations)
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1. SURFACE (calculée, en ha) + SOURCE
-- ---------------------------------------------------------------------
UPDATE parcellaire.parcelles
SET surface        = round((ST_Area(geom) / 10000)::numeric, 2),
    source_origine = 'logiciel'
WHERE geom IS NOT NULL;


-- ---------------------------------------------------------------------
-- 2. EXPLOITATIONS — parcellaires d'un seul tenant (K-means)
-- Autant de groupes que d'exploitations ; si la table contient d'autres
-- exploitations, filtrer les deux sous-requêtes (WHERE code_expl LIKE 'EXPL%')
-- ---------------------------------------------------------------------
WITH groupes AS (
  SELECT id,
         ST_ClusterKMeans(ST_Centroid(geom),
                          (SELECT count(*)::int FROM referentiel.exploitation)) OVER () + 1 AS k
  FROM parcellaire.parcelles
  WHERE geom IS NOT NULL
),
expl AS (
  SELECT code_expl, row_number() OVER (ORDER BY code_expl) AS k
  FROM referentiel.exploitation
)
UPDATE parcellaire.parcelles p
SET code_expl = e.code_expl
FROM groupes g
JOIN expl e ON e.k = g.k
WHERE p.id = g.id;


-- ---------------------------------------------------------------------
-- 3. ÎLOTS — parcelles qui se touchent, au sein d'une même exploitation
-- eps := 0 : contact réel (bord ou sommet) ; numérotation à partir de 1
-- par exploitation
-- ---------------------------------------------------------------------
WITH ilots AS (
  SELECT id,
         ST_ClusterDBSCAN(geom, eps := 0, minpoints := 1)
           OVER (PARTITION BY code_expl) + 1 AS num
  FROM parcellaire.parcelles
  WHERE geom IS NOT NULL
    AND code_expl IS NOT NULL
)
UPDATE parcellaire.parcelles p
SET num_ilot = i.num::text
FROM ilots i
WHERE p.id = i.id;


-- ---------------------------------------------------------------------
-- 4. LIBELLÉS — lieu-dit + complément une fois sur deux
-- ---------------------------------------------------------------------
UPDATE parcellaire.parcelles
SET libelle =
  (ARRAY['La Noue','Les Ouches','La Lande','Le Pré Long','La Grande Pièce','Les Grandes Pièces',
         'Le Champ Rond','La Croix','La Butte','Le Fief','Les Fiefs','La Bossardière','La Rivière',
         'Le Marais','La Prée','Les Prés','Le Bois','La Garenne','La Mare','Les Terres Rouges',
         'La Vigne','Les Vignes','Le Clos','Le Grand Clos','La Pâture','Les Pâtis','La Gâtine',
         'Le Chêne','Les Chaumes','La Fosse','Le Moulin','La Métairie','La Borderie','La Coudre',
         'L''Ouche','La Touche','La Cour','Le Puits','La Plaine','Les Rochettes','La Brosse',
         'Le Plessis','La Vallée','Le Coteau','La Pièce Neuve','Le Champ Long','La Haie',
         'Les Landes','La Barre','Le Pas'])[1 + floor(random() * 50)::int]
  ||
  CASE WHEN random() < 0.5 THEN ''
       ELSE ' ' || (ARRAY['du Moulin','du Bourg','de la Croix','du Chêne','de la Mare','du Bois',
                          'de la Route','du Haut','du Bas','Nord','Sud','de l''Étang','des Saules',
                          'du Puits','de la Gare','du Calvaire','de la Fontaine','des Peupliers',
                          'de la Lande','du Château','des Noyers','de l''Église','de la Ferme',
                          'du Ruisseau','des Ormeaux'])[1 + floor(random() * 25)::int]
  END
WHERE geom IS NOT NULL;


-- ---------------------------------------------------------------------
-- 5. CULTURES N, N-1, N-2 — rotations réalistes
-- Chaque parcelle reçoit une rotation (tirage pondéré) et une position
-- dans le cycle ; N-1 et N-2 = positions précédentes
-- ---------------------------------------------------------------------
WITH tirage AS (
  SELECT id,
         -- pondération : 20 cases ; la betterave (10) n'en a qu'une
         (ARRAY[1,1,1,1,2,2,2,2,3,3,4,4,5,6,6,7,7,8,9,10])[1 + floor(random() * 20)::int] AS r,
         2 + floor(random() * 1000)::int AS pos   -- >= 2 pour que pos-2 reste positif
  FROM parcellaire.parcelles
  WHERE geom IS NOT NULL
),
rot AS (
  SELECT id, pos,
         CASE r
           WHEN 1  THEN ARRAY['Colza d''hiver','Blé tendre d''hiver','Orge d''hiver']
           WHEN 2  THEN ARRAY['Maïs grain','Blé tendre d''hiver']
           WHEN 3  THEN ARRAY['Tournesol','Blé tendre d''hiver','Maïs grain','Blé dur d''hiver']
           WHEN 4  THEN ARRAY['Prairie temporaire','Prairie temporaire','Prairie temporaire',
                              'Maïs ensilage','Blé tendre d''hiver']
           WHEN 5  THEN ARRAY['Pois protéagineux','Blé tendre d''hiver','Maïs grain','Orge de printemps']
           WHEN 6  THEN ARRAY['Prairie permanente']
           WHEN 7  THEN ARRAY['Lin fibre','Blé tendre d''hiver','Colza d''hiver','Blé tendre d''hiver','Orge d''hiver']
           WHEN 8  THEN ARRAY['Luzerne','Luzerne','Luzerne','Blé tendre d''hiver','Maïs grain','Triticale']
           WHEN 9  THEN ARRAY['Féverole','Blé tendre d''hiver','Maïs ensilage','Triticale']
           WHEN 10 THEN ARRAY['Betterave sucrière','Blé tendre d''hiver','Lin fibre','Blé tendre d''hiver']
         END AS cycle
  FROM tirage
)
UPDATE parcellaire.parcelles p
SET culture    = r.cycle[1 + (r.pos)     % array_length(r.cycle, 1)],
    culture_n1 = r.cycle[1 + (r.pos - 1) % array_length(r.cycle, 1)],
    culture_n2 = r.cycle[1 + (r.pos - 2) % array_length(r.cycle, 1)]
FROM rot r
WHERE p.id = r.id;


-- ---------------------------------------------------------------------
-- 6. ID_LOGICIEL_INTERNE — LOG + 7 chiffres, à partir de 1048200,
-- petits trous dans la numérotation, ordre exploitation / îlot
-- ---------------------------------------------------------------------
UPDATE parcellaire.parcelles SET id_logiciel_interne = NULL;   -- évite un conflit d'unicité

WITH pas AS (
  SELECT id, code_expl, num_ilot,
         1 + floor(random() * 4)::int AS saut
  FROM parcellaire.parcelles
),
numeros AS (
  SELECT id,
         1048200 + sum(saut) OVER (ORDER BY code_expl, num_ilot::int, id) AS n
  FROM pas
)
UPDATE parcellaire.parcelles p
SET id_logiciel_interne = 'LOG' || lpad(n.n::text, 7, '0')
FROM numeros n
WHERE p.id = n.id;


-- ---------------------------------------------------------------------
-- 7. DÉPÔT DES EXPLOITATIONS — dépôt le plus proche du centre
-- du parcellaire
-- ---------------------------------------------------------------------
WITH centres AS (
  SELECT code_expl, ST_Centroid(ST_Collect(geom)) AS geom
  FROM parcellaire.parcelles
  WHERE geom IS NOT NULL
    AND code_expl IS NOT NULL
  GROUP BY code_expl
)
UPDATE referentiel.exploitation e
SET depot = d.code_site
FROM centres c
CROSS JOIN LATERAL (
  SELECT code_site
  FROM referentiel.depots
  WHERE geom IS NOT NULL
  ORDER BY geom <-> c.geom
  LIMIT 1
) d
WHERE e.code_expl = c.code_expl;


-- ---------------------------------------------------------------------
-- 8. COMMANDES — import logiciel (parcelle fournie)
-- Le trigger 1 pose statut_rattachement = 'logiciel' et remplit le
-- snapshot ; toutes en 'a_faire' (realise refusé sans prélèvement)
-- ---------------------------------------------------------------------
INSERT INTO analyses_sol.commandes
  (id_commande_logiciel, code_expl, campagne, statut, parcelle_id, geom,
   type_analyse, depot)
SELECT
  'CMD' || lpad((204500 + row_number() OVER (ORDER BY s.code_expl, s.id_logiciel_interne))::text, 7, '0'),
  s.code_expl,
  s.campagne,
  'a_faire',
  s.id,
  ST_PointOnSurface(s.geom),          -- point garanti à l'intérieur de la parcelle
  (ARRAY['Standard','Standard','Standard','Complète','Complète + oligo-éléments'])
    [1 + floor(random() * 5)::int],
  e.depot
FROM (
  SELECT *
  FROM parcellaire.parcelles
  WHERE geom IS NOT NULL
    AND code_expl IS NOT NULL
  ORDER BY random()
  LIMIT 120
) s
LEFT JOIN referentiel.exploitation e ON e.code_expl = s.code_expl;


-- ---------------------------------------------------------------------
-- 9. MODE DE PRÉLÈVEMENT — 55 % preleveur au total, variable par dépôt
-- Score = aléatoire + biais du dépôt (ordre des code_site) ;
-- les 55 % de meilleurs scores → preleveur
-- ---------------------------------------------------------------------
WITH biais AS (
  SELECT code_site,
         (ARRAY[0.25, 0.10, -0.10, -0.25])[(row_number() OVER (ORDER BY code_site))::int] AS b
  FROM referentiel.depots
),
classement AS (
  SELECT c.commande_id,
         percent_rank() OVER (ORDER BY random() + coalesce(b.b, 0) DESC) AS rang
  FROM analyses_sol.commandes c
  LEFT JOIN biais b ON b.code_site = c.depot
)
UPDATE analyses_sol.commandes c
SET mode_prelevement = CASE WHEN k.rang < 0.55 THEN 'preleveur' ELSE 'agri' END
FROM classement k
WHERE c.commande_id = k.commande_id;


-- ---------------------------------------------------------------------
-- 10. PRÉLÈVEMENTS — 40 / 33 / 27 / 20 % des commandes selon le dépôt
-- · preleveur : point aléatoire dans la parcelle ; agri : NULL → trigger 4
-- · statut 'preleve', code-barres 10 chiffres (commence par 1)
-- · le trigger 2 passe chaque commande en 'realise'
-- ---------------------------------------------------------------------
WITH taux AS (
  SELECT code_site,
         (ARRAY[0.40, 0.33, 0.27, 0.20])[(row_number() OVER (ORDER BY code_site))::int] AS t
  FROM referentiel.depots
),
choix AS (
  SELECT c.commande_id, c.mode_prelevement, c.parcelle_id, c.code_expl,
         percent_rank() OVER (PARTITION BY c.depot ORDER BY random()) AS rang,
         coalesce(t.t, 0.30) AS taux,
         current_date - floor(random() * 45)::int AS d_prel,
         1 + floor(random() * 15)::int AS saut
  FROM analyses_sol.commandes c
  LEFT JOIN taux t ON t.code_site = c.depot
  WHERE c.statut = 'a_faire'
),
retenus AS (
  SELECT *,
         1046382000 + sum(saut) OVER (ORDER BY d_prel, commande_id) AS num_cb
  FROM choix
  WHERE rang < taux
)
INSERT INTO analyses_sol.prelevements_sol
  (commande_id, geom, date_prelevement, code_barre, statut, preleveur)
SELECT
  r.commande_id,
  CASE WHEN r.mode_prelevement = 'preleveur'
       THEN ST_GeometryN(ST_GeneratePoints(p.geom, 1), 1) END,
  r.d_prel,
  r.num_cb::text,
  'preleve',
  CASE WHEN r.mode_prelevement = 'preleveur'
       THEN (ARRAY['Thomas Lebrun','Julie Marchand','Antoine Guérin','Camille Roussel'])
            [1 + floor(random() * 4)::int]
       ELSE e.libelle_exploitation END
FROM retenus r
LEFT JOIN parcellaire.parcelles p    ON p.id = r.parcelle_id
LEFT JOIN referentiel.exploitation e ON e.code_expl = r.code_expl;


-- ---------------------------------------------------------------------
-- 11. CONTRÔLES (à lancer un par un : l'éditeur Supabase n'affiche
-- que le dernier résultat)
-- ---------------------------------------------------------------------

-- Parcelles par exploitation
SELECT code_expl, count(*) AS nb_parcelles, round(sum(surface), 1) AS surface_ha
FROM parcellaire.parcelles
GROUP BY code_expl
ORDER BY code_expl;

-- Assolement
SELECT culture, count(*) AS nb, round(sum(surface), 0) AS ha
FROM parcellaire.parcelles
GROUP BY culture
ORDER BY ha DESC;

-- Unicité des id_logiciel_interne (nb = nb_distincts)
SELECT count(*) AS nb, count(DISTINCT id_logiciel_interne) AS nb_distincts,
       min(id_logiciel_interne), max(id_logiciel_interne)
FROM parcellaire.parcelles;

-- Rattachement et snapshot des commandes (uniquement 'logiciel', snapshot rempli)
SELECT statut_rattachement, mode_prelevement, count(*),
       count(nom_parcelle) AS snapshot_rempli
FROM analyses_sol.commandes
GROUP BY 1, 2;

-- Mode de prélèvement par dépôt (TOTAL = 55)
SELECT coalesce(d.nom_site, '(sans dépôt)') AS depot,
       count(*) AS nb,
       round(100.0 * count(*) FILTER (WHERE mode_prelevement = 'preleveur') / count(*)) AS pct_preleveur
FROM analyses_sol.commandes c
LEFT JOIN referentiel.depots d ON d.code_site = c.depot
GROUP BY 1
UNION ALL
SELECT 'TOTAL', count(*),
       round(100.0 * count(*) FILTER (WHERE mode_prelevement = 'preleveur') / count(*))
FROM analyses_sol.commandes
ORDER BY 1;

-- Taux de réalisation par dépôt
SELECT coalesce(d.nom_site, '(sans dépôt)') AS depot,
       count(*) AS nb_commandes,
       count(*) FILTER (WHERE c.statut = 'realise') AS realisees,
       round(100.0 * count(*) FILTER (WHERE c.statut = 'realise') / count(*)) AS pct
FROM analyses_sol.commandes c
LEFT JOIN referentiel.depots d ON d.code_site = c.depot
GROUP BY 1
ORDER BY 1;

-- Aucune commande 'realise' sans prélèvement (doit renvoyer 0)
SELECT count(*) FROM analyses_sol.commandes c
WHERE c.statut = 'realise'
  AND NOT EXISTS (SELECT 1 FROM analyses_sol.prelevements_sol p WHERE p.commande_id = c.commande_id);

-- Prélèvements agri au point de la commande (trigger 4, doit renvoyer 0)
SELECT count(*) FROM analyses_sol.prelevements_sol p
JOIN analyses_sol.commandes c USING (commande_id)
WHERE c.mode_prelevement = 'agri' AND NOT ST_Equals(p.geom, c.geom);

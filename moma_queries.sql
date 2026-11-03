

-- 0.1 Tables
CREATE TABLE artists (
    artist_id    INTEGER PRIMARY KEY,
    name         TEXT,
    nationality  TEXT,
    gender       TEXT,
    birth_year   INTEGER,
    death_year   INTEGER,
    author_type  TEXT
);

CREATE TABLE artworks (
    artwork_id         INTEGER PRIMARY KEY,
    title              TEXT,
    date_text          TEXT,
    create_year        INTEGER,
    date_approx        BOOLEAN,
    acq_date           DATE,
    acq_year           INTEGER,
    acq_decade         INTEGER,
    create_decade      INTEGER,
    years_to_acquire   INTEGER,
    acq_before_create  BOOLEAN,
    classification     TEXT,
    department         TEXT,
    medium             TEXT,
    credit             TEXT,
    height_cm          NUMERIC,
    width_cm           NUMERIC,
    area_cm2           NUMERIC
);

CREATE TABLE artwork_artists (
    artwork_id  INTEGER REFERENCES artworks(artwork_id),
    artist_id   INTEGER REFERENCES artists(artist_id)
);

-- 0.2 Load CSV files (files are in C:\temp). Order matters.
COPY public.artists (artist_id, name, nationality, gender,
                     birth_year, death_year, author_type)
FROM 'C:/temp/artists_clean.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8');

COPY public.artworks (artwork_id, title, date_text, create_year, date_approx,
                      acq_date, acq_year, acq_decade, create_decade,
                      years_to_acquire, acq_before_create, classification,
                      department, medium, credit, height_cm, width_cm, area_cm2)
FROM 'C:/temp/artworks_clean.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8');

COPY public.artwork_artists (artwork_id, artist_id)
FROM 'C:/temp/artwork_artists.csv'
WITH (FORMAT csv, HEADER true, DELIMITER ',', ENCODING 'UTF8');

-- 0.3 Check row counts. Expected: 15091, 130262, 142176
SELECT 'artists' AS table_name, COUNT(*) AS row_count FROM artists
UNION ALL SELECT 'artworks', COUNT(*) FROM artworks
UNION ALL SELECT 'artwork_artists', COUNT(*) FROM artwork_artists;

-- 0.4 Calendar table for Power BI (Time Intelligence)
CREATE TABLE dim_date AS
SELECT d::date                              AS date,
       EXTRACT(YEAR FROM d)::int            AS year,
       EXTRACT(QUARTER FROM d)::int         AS quarter,
       EXTRACT(MONTH FROM d)::int           AS month_number,
       TO_CHAR(d, 'Mon')                    AS month_name,
       EXTRACT(YEAR FROM d)::int / 10 * 10  AS decade
FROM generate_series('1929-01-01'::timestamp,
                     '2016-12-31'::timestamp,
                     interval '1 day') AS d;

ALTER TABLE dim_date ADD PRIMARY KEY (date);

-- Checks. Expected: 32142 and 0
SELECT COUNT(*) AS days FROM dim_date;

SELECT COUNT(*) AS artworks_without_date_row
FROM artworks a
LEFT JOIN dim_date d ON d.date = a.acq_date
WHERE a.acq_date IS NOT NULL AND d.date IS NULL;


-- ============================================================
-- QUERY 1. Share of women among authorships by decade of acquisition
-- Tools: CTE, JOIN, FILTER, aggregation
-- ============================================================
WITH credits AS (
    SELECT aw.acq_decade,
           a.gender
    FROM artwork_artists aa
    JOIN artworks aw ON aw.artwork_id = aa.artwork_id
    JOIN artists  a  ON a.artist_id  = aa.artist_id
    WHERE aw.acq_decade IS NOT NULL
)
SELECT acq_decade,
       COUNT(*) AS credits,
       COUNT(*) FILTER (WHERE gender = 'Female') AS female_credits,
       ROUND(100.0 * COUNT(*) FILTER (WHERE gender = 'Female') / COUNT(*), 1) AS female_pct
FROM credits
GROUP BY acq_decade
ORDER BY acq_decade;


-- ============================================================
-- QUERY 2. Top 3 nationalities in each department
-- Tools: 3 CTEs, ROW_NUMBER, SUM() OVER (PARTITION BY ...)
-- ============================================================
WITH authorships AS (
    SELECT aw.department,
           a.nationality
    FROM artwork_artists aa
    JOIN artworks aw ON aw.artwork_id = aa.artwork_id
    JOIN artists  a  ON a.artist_id  = aa.artist_id
    WHERE a.nationality <> 'Unknown'
),
counted AS (
    SELECT department, nationality, COUNT(*) AS credits
    FROM authorships
    GROUP BY department, nationality
),
ranked AS (
    SELECT department, nationality, credits,
           ROUND(100.0 * credits / SUM(credits) OVER (PARTITION BY department), 1) AS share_pct,
           ROW_NUMBER() OVER (PARTITION BY department ORDER BY credits DESC) AS rank_in_dept
    FROM counted
)
SELECT department, rank_in_dept, nationality, credits, share_pct
FROM ranked
WHERE rank_in_dept <= 3
ORDER BY department, rank_in_dept;


-- ============================================================
-- QUERY 3. Artworks acquired per year and change vs previous year
-- Tools: CTE, LAG, NULLIF
-- ============================================================
WITH yearly AS (
    SELECT acq_year, COUNT(*) AS artworks_acquired
    FROM artworks
    WHERE acq_year IS NOT NULL
    GROUP BY acq_year
)
SELECT acq_year,
       artworks_acquired,
       LAG(artworks_acquired) OVER (ORDER BY acq_year) AS prev_year,
       artworks_acquired - LAG(artworks_acquired) OVER (ORDER BY acq_year) AS change,
       ROUND(100.0 * (artworks_acquired - LAG(artworks_acquired) OVER (ORDER BY acq_year))
             / NULLIF(LAG(artworks_acquired) OVER (ORDER BY acq_year), 0), 1) AS change_pct
FROM yearly
ORDER BY acq_year;


-- ============================================================
-- QUERY 3b-A. Which departments drive the surge years
-- ============================================================
WITH by_dept AS (
    SELECT acq_year, department, COUNT(*) AS artworks
    FROM artworks
    WHERE acq_year IN (1964, 1968, 1974, 2001, 2005, 2008)
    GROUP BY acq_year, department
),
ranked AS (
    SELECT acq_year, department, artworks,
           ROUND(100.0 * artworks / SUM(artworks) OVER (PARTITION BY acq_year), 1) AS share_pct,
           ROW_NUMBER() OVER (PARTITION BY acq_year ORDER BY artworks DESC) AS rn
    FROM by_dept
)
SELECT acq_year, department, artworks, share_pct
FROM ranked
WHERE rn <= 2
ORDER BY acq_year, rn;


-- ============================================================
-- QUERY 3b-B. Who gave the artworks in the surge years (credit line)
-- ============================================================
WITH by_credit AS (
    SELECT acq_year, LEFT(credit, 60) AS credit_line, COUNT(*) AS artworks
    FROM artworks
    WHERE acq_year IN (1964, 1968, 1974, 2001, 2005, 2008)
    GROUP BY acq_year, LEFT(credit, 60)
),
ranked AS (
    SELECT acq_year, credit_line, artworks,
           ROW_NUMBER() OVER (PARTITION BY acq_year ORDER BY artworks DESC) AS rn
    FROM by_credit
)
SELECT acq_year, credit_line, artworks
FROM ranked
WHERE rn <= 2
ORDER BY acq_year, rn;


-- ============================================================
-- QUERY 3c. Share of women: before/after 1990, normal years vs surge years
-- Surge year = more than 3000 artworks acquired in that year (our choice)
-- Hypothesis H1: share of women is higher after 1990
-- ============================================================
WITH yearly AS (
    SELECT acq_year, COUNT(*) AS artworks_acquired
    FROM artworks
    WHERE acq_year IS NOT NULL
    GROUP BY acq_year
),
credits AS (
    SELECT aw.acq_year,
           (y.artworks_acquired > 3000) AS is_surge_year,
           a.gender
    FROM artwork_artists aa
    JOIN artworks aw ON aw.artwork_id = aa.artwork_id
    JOIN artists  a  ON a.artist_id  = aa.artist_id
    JOIN yearly   y  ON y.acq_year   = aw.acq_year
    WHERE a.gender IN ('Male', 'Female')
)
SELECT CASE WHEN acq_year < 1990 THEN 'before 1990' ELSE '1990 and later' END AS period,
       is_surge_year,
       COUNT(*) AS credits,
       COUNT(*) FILTER (WHERE gender = 'Female') AS female_credits,
       ROUND(100.0 * COUNT(*) FILTER (WHERE gender = 'Female') / COUNT(*), 1) AS female_pct
FROM credits
GROUP BY 1, 2
ORDER BY 1, 2;


-- ============================================================
-- QUERY 4-A. Artist segments by number of works (CASE)
-- Hypothesis H3: artists with 21+ works have a lower share of women
-- ============================================================
WITH per_artist AS (
    SELECT a.artist_id, a.gender, COUNT(*) AS works
    FROM artwork_artists aa
    JOIN artists a ON a.artist_id = aa.artist_id
    WHERE a.gender IN ('Male', 'Female')
    GROUP BY a.artist_id, a.gender
),
segmented AS (
    SELECT gender, works,
           CASE WHEN works = 1  THEN '1 work'
                WHEN works <= 5  THEN '2-5 works'
                WHEN works <= 20 THEN '6-20 works'
                ELSE '21+ works' END AS segment
    FROM per_artist
)
SELECT segment,
       COUNT(*) AS artists,
       COUNT(*) FILTER (WHERE gender = 'Female') AS female_artists,
       ROUND(100.0 * COUNT(*) FILTER (WHERE gender = 'Female') / COUNT(*), 1) AS female_pct,
       SUM(works) AS total_works
FROM segmented
GROUP BY segment
ORDER BY MIN(works);


-- ============================================================
-- QUERY 4-B. Ten equal groups of artists by number of works (NTILE)
-- Note: artists with equal values can fall into different groups
-- ============================================================
WITH per_artist AS (
    SELECT a.artist_id, a.gender, COUNT(*) AS works
    FROM artwork_artists aa
    JOIN artists a ON a.artist_id = aa.artist_id
    WHERE a.gender IN ('Male', 'Female')
    GROUP BY a.artist_id, a.gender
),
ranked AS (
    SELECT gender, works,
           NTILE(10) OVER (ORDER BY works DESC) AS decile
    FROM per_artist
)
SELECT decile,
       COUNT(*) AS artists,
       MIN(works) AS min_works,
       MAX(works) AS max_works,
       ROUND(100.0 * COUNT(*) FILTER (WHERE gender = 'Female') / COUNT(*), 1) AS female_pct
FROM ranked
GROUP BY decile
ORDER BY decile;

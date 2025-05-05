-- Step 1: Extract raw RFM metrics per customer
WITH base_rfm AS (
  SELECT
    CT.CustomerID,
    -- Recency: days since last purchase as of 2022-09-01
    DATEDIFF(DAY, MAX(CT.Purchase_Date), '2022-09-01') AS recency,
    
    -- Frequency: number of distinct purchase dates
    COUNT(DISTINCT CAST(CT.Purchase_Date AS DATE)) AS raw_frequency,
    
    -- Monetary: total purchase value (GMV)
    SUM(CT.GMV) AS raw_monetary,
    
    -- Customer sign-up date
    CR.Created_Date
  FROM customer_transaction CT
  JOIN customer_registered CR 
    ON CT.CustomerID = CR.ID
  WHERE CR.StopDate IS NULL -- Exclude churned customers
  GROUP BY CT.CustomerID, CR.Created_Date
),

-- Step 2: Normalize frequency and monetary by customer tenure (in years)
normalized_rfm AS (
  SELECT
    CustomerID,
    recency,
    
    -- Annualized frequency = frequency / customer tenure (in years)
    CAST(raw_frequency * 1.0 / NULLIF(DATEDIFF(YEAR, Created_Date, '2022-09-01'), 0) 
         AS DECIMAL(10,3)) AS frequency,
    
    -- Annualized monetary = monetary / customer tenure (in years)
    CAST(raw_monetary * 1.0 / NULLIF(DATEDIFF(YEAR, Created_Date, '2022-09-01'), 0) 
         AS DECIMAL(18,0)) AS monetary
  FROM base_rfm
),

-- Step 3: Rank customers for quartile scoring using RFM metrics
ranked_rfm AS (
  SELECT *,
    -- Lower recency is better, so rank ascending
    ROW_NUMBER() OVER (ORDER BY recency ASC) AS rn_recency,
    
    -- Higher frequency is better, so rank descending
    ROW_NUMBER() OVER (ORDER BY frequency DESC) AS rn_frequency,
    
    -- Higher monetary is better, so rank descending
    ROW_NUMBER() OVER (ORDER BY monetary DESC) AS rn_monetary
  FROM normalized_rfm
),

-- Count total customers for quartile thresholds
quartiles AS (
  SELECT COUNT(*) AS total_customers FROM ranked_rfm
),

-- Step 4: Assign quartile scores (1–4) for R, F, M
scored_rfm AS (
  SELECT
    r.*,
    
    -- Recency quartile (inverted scale: lower recency → higher score)
    CASE
      WHEN rn_recency <= q.total_customers * 0.25 THEN 4
      WHEN rn_recency <= q.total_customers * 0.50 THEN 3
      WHEN rn_recency <= q.total_customers * 0.75 THEN 2
      ELSE 1
    END AS recency_rank,
    
    -- Frequency quartile
    CASE
      WHEN rn_frequency <= q.total_customers * 0.25 THEN 4
      WHEN rn_frequency <= q.total_customers * 0.50 THEN 3
      WHEN rn_frequency <= q.total_customers * 0.75 THEN 2
      ELSE 1
    END AS frequency_rank,
    
    -- Monetary quartile
    CASE
      WHEN rn_monetary <= q.total_customers * 0.25 THEN 4
      WHEN rn_monetary <= q.total_customers * 0.50 THEN 3
      WHEN rn_monetary <= q.total_customers * 0.75 THEN 2
      ELSE 1
    END AS monetary_rank

  FROM ranked_rfm r
  CROSS JOIN quartiles q
),

-- Step 5: Map RFM scores to BCG segments
final_result AS (
  SELECT *,
    -- RFM score string (e.g., "434")
    CONCAT(recency_rank, frequency_rank, monetary_rank) AS rfm,

    -- BCG segmentation logic
    CASE
      WHEN recency_rank >= 3 AND frequency_rank >= 3 AND monetary_rank >= 3 
        THEN 'Star'
      WHEN recency_rank <= 2 AND frequency_rank >= 3 AND monetary_rank >= 3 
        THEN 'Cash Cows'
      WHEN recency_rank >= 3 AND frequency_rank <= 2 AND monetary_rank <= 2 
        THEN 'Question Marks'
      WHEN recency_rank <= 2 AND frequency_rank <= 2 AND monetary_rank <= 2 
        THEN 'Dogs'
      ELSE 'Others'
    END AS bcg
  FROM scored_rfm
)

-- Final output: RFM metrics, scores, and segment for each customer
SELECT
  CustomerID,
  recency,
  FORMAT(frequency, 'N3') AS frequency,
  FORMAT(monetary, 'N0') AS monetary,
  recency_rank,
  frequency_rank,
  monetary_rank,
  rfm,
  bcg
FROM final_result
ORDER BY CustomerID;

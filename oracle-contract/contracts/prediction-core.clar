;; Nexus Oracles - Core Prediction Contract
;; Manages prediction lifecycle, wagering, and outcome validation

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-PREDICTION-NOT-FOUND (err u101))
(define-constant ERR-PREDICTION-ENDED (err u102))
(define-constant ERR-PREDICTION-NOT-ENDED (err u103))
(define-constant ERR-INVALID-OUTCOME (err u104))
(define-constant ERR-INSUFFICIENT-FUNDS (err u105))
(define-constant ERR-ALREADY-VALIDATED (err u106))
(define-constant ERR-INVALID-WAGER (err u107))
(define-constant ERR-PREDICTION-PAUSED (err u108))

;; Data Variables
(define-data-var next-prediction-id uint u1)
(define-data-var platform-fee-rate uint u300) ;; 3% in basis points
(define-data-var emergency-pause bool false)

;; Data Maps
(define-map predictions
  { prediction-id: uint }
  {
    creator: principal,
    title: (string-utf8 256),
    description: (string-utf8 1024),
    category: (string-utf8 64),
    outcomes: (list 10 (string-utf8 128)),
    end-time: uint,
    total-pool: uint,
    outcome-pools: (list 10 uint),
    status: (string-ascii 20), ;; "active", "ended", "validated", "disputed"
    winning-outcome: (optional uint),
    created-at: uint,
    validation-deadline: uint
  }
)

(define-map wagers
  { prediction-id: uint, user: principal, outcome: uint }
  { amount: uint, timestamp: uint }
)

(define-map user-total-wagers
  { prediction-id: uint, user: principal }
  { total-amount: uint }
)

(define-map validations
  { prediction-id: uint, validator: principal }
  { outcome: uint, timestamp: uint, reputation-weight: uint }
)

(define-map prediction-stats
  { prediction-id: uint }
  {
    total-wagers: uint,
    unique-bettors: uint,
    validation-count: uint,
    consensus-outcome: (optional uint),
    consensus-confidence: uint
  }
)

;; Read-only functions
(define-read-only (get-prediction-details (prediction-id uint))
  (map-get? predictions { prediction-id: prediction-id })
)

(define-read-only (get-prediction-stats (prediction-id uint))
  (map-get? prediction-stats { prediction-id: prediction-id })
)

(define-read-only (get-user-wager (prediction-id uint) (user principal) (outcome uint))
  (map-get? wagers { prediction-id: prediction-id, user: user, outcome: outcome })
)

(define-read-only (get-user-total-wager (prediction-id uint) (user principal))
  (map-get? user-total-wagers { prediction-id: prediction-id, user: user })
)

(define-read-only (get-validation (prediction-id uint) (validator principal))
  (map-get? validations { prediction-id: prediction-id, validator: validator })
)

(define-read-only (get-current-prediction-id)
  (var-get next-prediction-id)
)

(define-read-only (is-prediction-active (prediction-id uint))
  (match (get-prediction-details prediction-id)
    prediction (and 
      (is-eq (get status prediction) "active")
      (< block-height (get end-time prediction))
      (not (var-get emergency-pause))
    )
    false
  )
)

(define-read-only (calculate-payout (prediction-id uint) (user principal) (outcome uint))
  (let (
    (prediction (unwrap! (get-prediction-details prediction-id) (err u0)))
    (user-wager (unwrap! (get-user-wager prediction-id user outcome) (err u0)))
    (winning-outcome (unwrap! (get winning-outcome prediction) (err u0)))
    (total-pool (get total-pool prediction))
    (outcome-pools (get outcome-pools prediction))
    (winning-pool (unwrap! (element-at outcome-pools winning-outcome) (err u0)))
  )
    (if (is-eq outcome winning-outcome)
      (ok (/ (* (get amount user-wager) total-pool) winning-pool))
      (ok u0)
    )
  )
)

;; Private functions
(define-private (update-outcome-pools (prediction-id uint) (outcome uint) (amount uint))
  (match (get-prediction-details prediction-id)
    prediction (let (
      (current-pools (get outcome-pools prediction))
      (current-amount (default-to u0 (element-at current-pools outcome)))
      (new-amount (+ current-amount amount))
      ;; Replace replace-at with map-based list reconstruction
      (new-pools (map + current-pools 
        (list 
          (if (is-eq outcome u0) amount u0)
          (if (is-eq outcome u1) amount u0)
          (if (is-eq outcome u2) amount u0)
          (if (is-eq outcome u3) amount u0)
          (if (is-eq outcome u4) amount u0)
          (if (is-eq outcome u5) amount u0)
          (if (is-eq outcome u6) amount u0)
          (if (is-eq outcome u7) amount u0)
          (if (is-eq outcome u8) amount u0)
          (if (is-eq outcome u9) amount u0)
        )
      ))
    )
      ;; Wrap map-set in begin block and ensure consistent response type
      (begin
        (map-set predictions
          { prediction-id: prediction-id }
          (merge prediction { 
            outcome-pools: new-pools,
            total-pool: (+ (get total-pool prediction) amount)
          })
        )
        (ok true)
      )
    )
    ERR-PREDICTION-NOT-FOUND
  )
)

(define-private (increment-prediction-stats (prediction-id uint) (is-new-bettor bool))
  (let (
    (current-stats (default-to 
      { total-wagers: u0, unique-bettors: u0, validation-count: u0, consensus-outcome: none, consensus-confidence: u0 }
      (get-prediction-stats prediction-id)
    ))
  )
    ;; Wrap map-set in begin block and ensure consistent response type
    (match (get-prediction-details prediction-id)
      prediction (begin
        (map-set prediction-stats
          { prediction-id: prediction-id }
          (merge current-stats {
            total-wagers: (+ (get total-wagers current-stats) u1),
            unique-bettors: (if is-new-bettor 
              (+ (get unique-bettors current-stats) u1)
              (get unique-bettors current-stats)
            )
          })
        )
        (ok true)
      )
      ERR-PREDICTION-NOT-FOUND
    )
  )
)

;; Public functions
(define-public (create-prediction 
  (title (string-utf8 256))
  (description (string-utf8 1024))
  (outcomes (list 10 (string-utf8 128)))
  (end-time uint)
  (category (string-utf8 64))
)
  (let (
    (prediction-id (var-get next-prediction-id))
    (validation-deadline (+ end-time u144)) ;; 24 hours after end-time (144 blocks)
  )
    (asserts! (not (var-get emergency-pause)) ERR-PREDICTION-PAUSED)
    (asserts! (> end-time block-height) (err u109)) ;; End time must be in future
    (asserts! (> (len outcomes) u1) (err u110)) ;; Must have at least 2 outcomes
    
    (map-set predictions
      { prediction-id: prediction-id }
      {
        creator: tx-sender,
        title: title,
        description: description,
        category: category,
        outcomes: outcomes,
        end-time: end-time,
        total-pool: u0,
        outcome-pools: (list u0 u0 u0 u0 u0 u0 u0 u0 u0 u0),
        status: "active",
        winning-outcome: none,
        created-at: block-height,
        validation-deadline: validation-deadline
      }
    )
    
    (map-set prediction-stats
      { prediction-id: prediction-id }
      {
        total-wagers: u0,
        unique-bettors: u0,
        validation-count: u0,
        consensus-outcome: none,
        consensus-confidence: u0
      }
    )
    
    (var-set next-prediction-id (+ prediction-id u1))
    (ok prediction-id)
  )
)

(define-public (place-wager (prediction-id uint) (outcome uint) (amount uint))
  (let (
    (prediction (unwrap! (get-prediction-details prediction-id) ERR-PREDICTION-NOT-FOUND))
    (current-wager (get-user-wager prediction-id tx-sender outcome))
    (current-total (get-user-total-wager prediction-id tx-sender))
    (is-new-bettor (is-none current-total))
  )
    (asserts! (is-prediction-active prediction-id) ERR-PREDICTION-ENDED)
    (asserts! (< outcome (len (get outcomes prediction))) ERR-INVALID-OUTCOME)
    (asserts! (> amount u0) ERR-INVALID-WAGER)
    
    ;; Transfer STX to contract
    (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
    
    ;; Fixed type error by properly handling optional values
    ;; Update wager records
    (map-set wagers
      { prediction-id: prediction-id, user: tx-sender, outcome: outcome }
      {
        amount: (+ amount (match current-wager
          some-wager (get amount some-wager)
          u0
        )),
        timestamp: block-height
      }
    )
    
    ;; Fixed type error by properly handling optional values
    ;; Update user total wager
    (map-set user-total-wagers
      { prediction-id: prediction-id, user: tx-sender }
      { total-amount: (+ amount (match current-total
        some-total (get total-amount some-total)
        u0
      )) }
    )
    
    ;; Update outcome pools and stats
    (try! (update-outcome-pools prediction-id outcome amount))
    (try! (increment-prediction-stats prediction-id is-new-bettor))
    
    (ok true)
  )
)

(define-public (validate-outcome (prediction-id uint) (outcome uint) (reputation-weight uint))
  (let (
    (prediction (unwrap! (get-prediction-details prediction-id) ERR-PREDICTION-NOT-FOUND))
    (existing-validation (get-validation prediction-id tx-sender))
  )
    (asserts! (is-eq (get status prediction) "ended") ERR-PREDICTION-NOT-ENDED)
    (asserts! (< block-height (get validation-deadline prediction)) (err u111)) ;; Validation period expired
    (asserts! (< outcome (len (get outcomes prediction))) ERR-INVALID-OUTCOME)
    (asserts! (is-none existing-validation) ERR-ALREADY-VALIDATED)
    
    ;; Record validation
    (map-set validations
      { prediction-id: prediction-id, validator: tx-sender }
      {
        outcome: outcome,
        timestamp: block-height,
        reputation-weight: reputation-weight
      }
    )
    
    ;; Update validation count
    (let (
      (current-stats (unwrap! (get-prediction-stats prediction-id) ERR-PREDICTION-NOT-FOUND))
    )
      (map-set prediction-stats
        { prediction-id: prediction-id }
        (merge current-stats {
          validation-count: (+ (get validation-count current-stats) u1)
        })
      )
    )
    
    (ok true)
  )
)

(define-public (finalize-prediction (prediction-id uint))
  (let (
    (prediction (unwrap! (get-prediction-details prediction-id) ERR-PREDICTION-NOT-FOUND))
  )
    (asserts! (is-eq (get status prediction) "active") (err u112))
    (asserts! (>= block-height (get end-time prediction)) ERR-PREDICTION-NOT-ENDED)
    
    ;; Update prediction status to ended
    (map-set predictions
      { prediction-id: prediction-id }
      (merge prediction { status: "ended" })
    )
    
    (ok true)
  )
)

(define-public (distribute-rewards (prediction-id uint))
  (let (
    (prediction (unwrap! (get-prediction-details prediction-id) ERR-PREDICTION-NOT-FOUND))
    (winning-outcome (unwrap! (get winning-outcome prediction) (err u113)))
    (total-pool (get total-pool prediction))
    (platform-fee (/ (* total-pool (var-get platform-fee-rate)) u10000))
    (distributable-amount (- total-pool platform-fee))
  )
    (asserts! (is-eq (get status prediction) "validated") (err u114))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    
    ;; Transfer platform fee
    (try! (as-contract (stx-transfer? platform-fee tx-sender CONTRACT-OWNER)))
    
    ;; Update prediction status
    (map-set predictions
      { prediction-id: prediction-id }
      (merge prediction { status: "distributed" })
    )
    
    (ok distributable-amount)
  )
)

;; Admin functions
(define-public (set-winning-outcome (prediction-id uint) (outcome uint))
  (let (
    (prediction (unwrap! (get-prediction-details prediction-id) ERR-PREDICTION-NOT-FOUND))
  )
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (is-eq (get status prediction) "ended") ERR-PREDICTION-NOT-ENDED)
    (asserts! (< outcome (len (get outcomes prediction))) ERR-INVALID-OUTCOME)
    
    (map-set predictions
      { prediction-id: prediction-id }
      (merge prediction { 
        winning-outcome: (some outcome),
        status: "validated"
      })
    )
    
    (ok true)
  )
)

(define-public (toggle-emergency-pause)
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (var-set emergency-pause (not (var-get emergency-pause)))
    (ok (var-get emergency-pause))
  )
)

(define-public (update-platform-fee (new-rate uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
    (asserts! (<= new-rate u1000) (err u115)) ;; Max 10% fee
    (var-set platform-fee-rate new-rate)
    (ok true)
  )
)

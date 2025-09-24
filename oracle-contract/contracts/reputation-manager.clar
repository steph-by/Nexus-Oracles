;; Reputation Manager Contract
;; A Clarity smart contract for managing oracle scores, expertise badges,
;; and influence multipliers in a decentralized reputation system

;; Error codes
(define-constant ERR-NOT-AUTHORIZED (err u300))
(define-constant ERR-ALREADY-EXISTS (err u301))
(define-constant ERR-DOES-NOT-EXIST (err u302))
(define-constant ERR-INVALID-SCORE (err u303))
(define-constant ERR-INVALID-CATEGORY (err u304))
(define-constant ERR-INSUFFICIENT-REPUTATION (err u305))
(define-constant ERR-BADGE-ALREADY-AWARDED (err u306))
(define-constant ERR-INVALID-MULTIPLIER (err u307))
(define-constant ERR-ORACLE-NOT-FOUND (err u308))
(define-constant ERR-INVALID-ACCURACY (err u309))
(define-constant ERR-COOLDOWN-ACTIVE (err u310))

;; Constants
(define-constant MAX-ACCURACY-SCORE u10000) ;; 100.00% (basis points)
(define-constant MIN-ACCURACY-SCORE u0)
(define-constant BASE-REPUTATION u1000)
(define-constant MAX-INFLUENCE-MULTIPLIER u500) ;; 5.00x multiplier
(define-constant MIN-INFLUENCE-MULTIPLIER u100) ;; 1.00x multiplier
(define-constant EXPERTISE-THRESHOLD u8000) ;; 80% accuracy required
(define-constant ORACLE-COOLDOWN-BLOCKS u144) ;; ~24 hours
(define-constant DECAY-RATE u10) ;; 0.1% per period

;; Role definitions
(define-constant ROLE-NONE u0)
(define-constant ROLE-ORACLE u1)
(define-constant ROLE-VALIDATOR u2)
(define-constant ROLE-ADMIN u3)

;; Badge levels
(define-constant BADGE-BRONZE u1)
(define-constant BADGE-SILVER u2)
(define-constant BADGE-GOLD u3)
(define-constant BADGE-PLATINUM u4)

;; Expertise categories
(define-constant CATEGORY-FINANCE u1)
(define-constant CATEGORY-TECHNOLOGY u2)
(define-constant CATEGORY-LEGAL u3)
(define-constant CATEGORY-HEALTHCARE u4)
(define-constant CATEGORY-EDUCATION u5)
(define-constant CATEGORY-GENERAL u6)

;; Data maps

;; User reputation profiles
(define-map user-reputation
  { address: principal }
  {
    base-score: uint,
    accuracy-score: uint,
    total-predictions: uint,
    correct-predictions: uint,
    influence-multiplier: uint,
    last-updated: uint,
    role: uint,
    active: bool
  }
)

;; Oracle accuracy tracking
(define-map oracle-scores
  { oracle: principal, category: uint }
  {
    accuracy-rate: uint,
    total-validations: uint,
    correct-validations: uint,
    last-validation: uint,
    streak: uint,
    best-streak: uint
  }
)

;; Expertise badges
(define-map expertise-badges
  { user: principal, category: uint }
  {
    badge-level: uint,
    earned-at: uint,
    accuracy-when-earned: uint,
    validations-count: uint,
    active: bool
  }
)

;; Influence multipliers by category
(define-map category-multipliers
  { user: principal, category: uint }
  {
    multiplier: uint,
    base-accuracy: uint,
    bonus-accuracy: uint,
    last-calculated: uint
  }
)

;; Oracle validation history
(define-map validation-history
  { oracle: principal, validation-id: uint }
  {
    category: uint,
    prediction: bool,
    actual-outcome: bool,
    confidence: uint,
    timestamp: uint,
    reward-earned: uint
  }
)

;; Category statistics
(define-map category-stats
  { category: uint }
  {
    total-oracles: uint,
    average-accuracy: uint,
    total-validations: uint,
    last-updated: uint
  }
)

;; Contract variables
(define-data-var contract-owner principal tx-sender)
(define-data-var validation-counter uint u0)
(define-data-var total-users uint u0)

;; Helper functions

(define-private (is-admin (address principal))
  (or 
    (is-eq address (var-get contract-owner))
    (is-eq (get-user-role address) ROLE-ADMIN)
  )
)

(define-private (is-validator (address principal))
  (>= (get-user-role address) ROLE-VALIDATOR)
)

(define-private (is-oracle (address principal))
  (>= (get-user-role address) ROLE-ORACLE)
)

(define-private (get-user-role (address principal))
  (default-to ROLE-NONE (get role (map-get? user-reputation { address: address })))
)

(define-private (user-exists (address principal))
  (is-some (map-get? user-reputation { address: address }))
)

(define-private (calculate-accuracy-rate (correct uint) (total uint))
  (if (is-eq total u0)
    u0
    (/ (* correct u10000) total)
  )
)

(define-private (apply-decay (score uint) (blocks-passed uint))
  (let ((decay-amount (/ (* score DECAY-RATE blocks-passed) u10000)))
    (if (> score decay-amount)
      (- score decay-amount)
      u0)
  )
)

(define-private (calculate-badge-level (accuracy uint) (validations uint))
  (if (and (>= accuracy u9500) (>= validations u100))
    BADGE-PLATINUM
    (if (and (>= accuracy u9000) (>= validations u50))
      BADGE-GOLD
      (if (and (>= accuracy u8500) (>= validations u25))
        BADGE-SILVER
        (if (and (>= accuracy u8000) (>= validations u10))
          BADGE-BRONZE
          u0))))
)

(define-private (calculate-reward (oracle principal) (confidence uint) (correct bool))
  (let (
    (base-reward u10)
    (confidence-multiplier (/ confidence u10))
    (accuracy-bonus (if correct confidence-multiplier u0))
  )
    (+ base-reward accuracy-bonus)
  )
)

(define-private (update-category-score (oracle principal) (category uint) (correct bool))
  (let (
    (current-score (default-to 
      { accuracy-rate: u0, total-validations: u0, correct-validations: u0, 
        last-validation: u0, streak: u0, best-streak: u0 }
      (map-get? oracle-scores { oracle: oracle, category: category })))
    (new-total (+ (get total-validations current-score) u1))
    (new-correct (if correct (+ (get correct-validations current-score) u1) (get correct-validations current-score)))
    (new-accuracy (calculate-accuracy-rate new-correct new-total))
    (new-streak (if correct (+ (get streak current-score) u1) u0))
    (new-best-streak (if (> new-streak (get best-streak current-score)) new-streak (get best-streak current-score)))
  )
    (begin
      (map-set oracle-scores
        { oracle: oracle, category: category }
        {
          accuracy-rate: new-accuracy,
          total-validations: new-total,
          correct-validations: new-correct,
          last-validation: block-height,
          streak: new-streak,
          best-streak: new-best-streak
        }
      )
      true
    )
  )
)

(define-private (update-overall-reputation (oracle principal) (correct bool) (confidence uint))
  (let (
    (profile (unwrap! (map-get? user-reputation { address: oracle }) ERR-DOES-NOT-EXIST))
    (new-total (+ (get total-predictions profile) u1))
    (new-correct (if correct (+ (get correct-predictions profile) u1) (get correct-predictions profile)))
    (new-accuracy (calculate-accuracy-rate new-correct new-total))
    (confidence-bonus (/ confidence u10))
    (new-base-score (if correct 
                      (+ (get base-score profile) confidence-bonus)
                      (if (> (get base-score profile) confidence-bonus)
                        (- (get base-score profile) confidence-bonus)
                        u0)))
  )
    (begin
      (map-set user-reputation
        { address: oracle }
        (merge profile {
          base-score: new-base-score,
          accuracy-score: new-accuracy,
          total-predictions: new-total,
          correct-predictions: new-correct,
          last-updated: block-height
        })
      )
      (ok true)
    )
  )
)

(define-private (update-category-statistics (category uint))
  (let (
    (current-stats (default-to 
      { total-oracles: u0, average-accuracy: u0, total-validations: u0, last-updated: u0 }
      (map-get? category-stats { category: category })))
  )
    (begin
      (map-set category-stats
        { category: category }
        (merge current-stats {
          total-validations: (+ (get total-validations current-stats) u1),
          last-updated: block-height
        })
      )
      true
    )
  )
)

(define-private (check-badge-eligibility (oracle principal) (category uint))
  (let (
    (oracle-score (map-get? oracle-scores { oracle: oracle, category: category }))
  )
    (match oracle-score
      score-data (let (
        (accuracy (get accuracy-rate score-data))
        (validations (get total-validations score-data))
        (badge-level (calculate-badge-level accuracy validations))
      )
        (if (> badge-level u0)
          (award-expertise-badge oracle category)
          (ok u0)))
      (ok u0))
  )
)

(define-private (update-influence-multiplier (user principal) (category uint))
  (calculate-influence-multiplier user category)
)

;; Public functions

;; User registration and management

(define-public (register-oracle)
  (begin
    (asserts! (not (user-exists tx-sender)) ERR-ALREADY-EXISTS)
    (map-set user-reputation
      { address: tx-sender }
      {
        base-score: BASE-REPUTATION,
        accuracy-score: u0,
        total-predictions: u0,
        correct-predictions: u0,
        influence-multiplier: MIN-INFLUENCE-MULTIPLIER,
        last-updated: block-height,
        role: ROLE-ORACLE,
        active: true
      }
    )
    (var-set total-users (+ (var-get total-users) u1))
    (ok true)
  )
)

(define-public (update-user-role (user principal) (new-role uint))
  (let ((profile (map-get? user-reputation { address: user })))
    (begin
      (asserts! (is-admin tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (is-some profile) ERR-DOES-NOT-EXIST)
      (asserts! (<= new-role ROLE-ADMIN) ERR-INVALID-SCORE)
      (map-set user-reputation
        { address: user }
        (merge (unwrap-panic profile) { role: new-role })
      )
      (ok true)
    )
  )
)

;; Oracle score management

(define-public (update-oracle-score 
  (oracle principal) 
  (category uint) 
  (prediction-correct bool) 
  (confidence uint)
)
  (let (
    (oracle-profile (map-get? user-reputation { address: oracle }))
    (oracle-score (map-get? oracle-scores { oracle: oracle, category: category }))
    (validation-id (var-get validation-counter))
  )
    (begin
      (asserts! (is-validator tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (is-some oracle-profile) ERR-DOES-NOT-EXIST)
      (asserts! (and (>= category CATEGORY-FINANCE) (<= category CATEGORY-GENERAL)) ERR-INVALID-CATEGORY)
      (asserts! (<= confidence u100) ERR-INVALID-SCORE)
      
      ;; Check cooldown
      (asserts! 
        (match oracle-score
          existing-score (>= (- block-height (get last-validation existing-score)) ORACLE-COOLDOWN-BLOCKS)
          true)
        ERR-COOLDOWN-ACTIVE)
      
      ;; Update oracle score for category
      (update-category-score oracle category prediction-correct)
      
      ;; Update overall reputation
      (try! (update-overall-reputation oracle prediction-correct confidence))
      
      ;; Record validation history
      (map-set validation-history
        { oracle: oracle, validation-id: validation-id }
        {
          category: category,
          prediction: prediction-correct,
          actual-outcome: prediction-correct,
          confidence: confidence,
          timestamp: block-height,
          reward-earned: (calculate-reward oracle confidence prediction-correct)
        }
      )
      
      ;; Update category statistics
      (update-category-statistics category)
      
      ;; Check for badge eligibility
      (try! (check-badge-eligibility oracle category))
      
      (var-set validation-counter (+ validation-id u1))
      (ok validation-id)
    )
  )
)

;; Badge management

(define-public (award-expertise-badge (user principal) (category uint))
  (let (
    (oracle-score (map-get? oracle-scores { oracle: user, category: category }))
    (existing-badge (map-get? expertise-badges { user: user, category: category }))
  )
    (begin
      (asserts! (is-validator tx-sender) ERR-NOT-AUTHORIZED)
      (asserts! (is-some oracle-score) ERR-ORACLE-NOT-FOUND)
      (asserts! (and (>= category CATEGORY-FINANCE) (<= category CATEGORY-GENERAL)) ERR-INVALID-CATEGORY)
      
      (let (
        (score-data (unwrap-panic oracle-score))
        (accuracy (get accuracy-rate score-data))
        (validations (get total-validations score-data))
        (badge-level (calculate-badge-level accuracy validations))
      )
        (begin
          (asserts! (> badge-level u0) ERR-INSUFFICIENT-REPUTATION)
          (asserts! (>= accuracy EXPERTISE-THRESHOLD) ERR-INSUFFICIENT-REPUTATION)
          
          ;; Check if badge already exists and is lower level
          (match existing-badge
            current-badge (asserts! (< (get badge-level current-badge) badge-level) ERR-BADGE-ALREADY-AWARDED)
            true)
          
          (map-set expertise-badges
            { user: user, category: category }
            {
              badge-level: badge-level,
              earned-at: block-height,
              accuracy-when-earned: accuracy,
              validations-count: validations,
              active: true
            }
          )
          
          ;; Update influence multiplier
          (try! (update-influence-multiplier user category))
          
          (ok badge-level)
        )
      )
    )
  )
)

;; Influence multiplier calculation

(define-public (calculate-influence-multiplier (user principal) (category uint))
  (let (
    (oracle-score (map-get? oracle-scores { oracle: user, category: category }))
    (badge (map-get? expertise-badges { user: user, category: category }))
    (user-profile (map-get? user-reputation { address: user }))
  )
    (begin
      (asserts! (user-exists user) ERR-DOES-NOT-EXIST)
      (asserts! (and (>= category CATEGORY-FINANCE) (<= category CATEGORY-GENERAL)) ERR-INVALID-CATEGORY)
      
      (let (
        (base-multiplier MIN-INFLUENCE-MULTIPLIER)
        (accuracy-bonus (match oracle-score
          score-data (/ (get accuracy-rate score-data) u100)
          u0))
        (badge-bonus (match badge
          badge-data (let ((level (get badge-level badge-data)))
            (if (is-eq level BADGE-PLATINUM) u100
              (if (is-eq level BADGE-GOLD) u75
                (if (is-eq level BADGE-SILVER) u50
                  (if (is-eq level BADGE-BRONZE) u25 u0)))))
          u0))
        (streak-bonus (match oracle-score
          score-data (/ (get best-streak score-data) u2)
          u0))
        (total-multiplier (+ base-multiplier accuracy-bonus badge-bonus streak-bonus))
        (final-multiplier (if (> total-multiplier MAX-INFLUENCE-MULTIPLIER) 
                           MAX-INFLUENCE-MULTIPLIER 
                           total-multiplier))
      )
        (begin
          (map-set category-multipliers
            { user: user, category: category }
            {
              multiplier: final-multiplier,
              base-accuracy: (match oracle-score score-data (get accuracy-rate score-data) u0),
              bonus-accuracy: accuracy-bonus,
              last-calculated: block-height
            }
          )
          (ok final-multiplier)
        )
      )
    )
  )
)

;; Read-only functions

(define-read-only (get-user-reputation (user principal))
  (map-get? user-reputation { address: user })
)

(define-read-only (get-oracle-score (oracle principal) (category uint))
  (map-get? oracle-scores { oracle: oracle, category: category })
)

(define-read-only (get-expertise-badge (user principal) (category uint))
  (map-get? expertise-badges { user: user, category: category })
)

(define-read-only (get-influence-multiplier (user principal) (category uint))
  (default-to MIN-INFLUENCE-MULTIPLIER 
    (get multiplier (map-get? category-multipliers { user: user, category: category })))
)

(define-read-only (get-validation-history (oracle principal) (validation-id uint))
  (map-get? validation-history { oracle: oracle, validation-id: validation-id })
)

(define-read-only (get-category-stats (category uint))
  (map-get? category-stats { category: category })
)

(define-read-only (get-user-accuracy (user principal))
  (match (map-get? user-reputation { address: user })
    profile (get accuracy-score profile)
    u0)
)

(define-read-only (get-user-badges (user principal))
  (let (
    (finance-badge (map-get? expertise-badges { user: user, category: CATEGORY-FINANCE }))
    (tech-badge (map-get? expertise-badges { user: user, category: CATEGORY-TECHNOLOGY }))
    (legal-badge (map-get? expertise-badges { user: user, category: CATEGORY-LEGAL }))
    (health-badge (map-get? expertise-badges { user: user, category: CATEGORY-HEALTHCARE }))
    (edu-badge (map-get? expertise-badges { user: user, category: CATEGORY-EDUCATION }))
    (general-badge (map-get? expertise-badges { user: user, category: CATEGORY-GENERAL }))
  )
    {
      finance: finance-badge,
      technology: tech-badge,
      legal: legal-badge,
      healthcare: health-badge,
      education: edu-badge,
      general: general-badge
    }
  )
)

(define-read-only (calculate-weighted-reputation (user principal))
  (match (map-get? user-reputation { address: user })
    profile (let (
      (base-score (get base-score profile))
      (accuracy-score (get accuracy-score profile))
      (influence-mult (get influence-multiplier profile))
      (weighted-score (/ (* base-score influence-mult) u100))
    )
      (+ weighted-score (/ accuracy-score u100)))
    u0)
)

(define-read-only (get-contract-stats)
  {
    total-users: (var-get total-users),
    total-validations: (var-get validation-counter),
    contract-owner: (var-get contract-owner)
  }
)

;; Initialize contract
(begin
  (try! (register-oracle))
  (map-set user-reputation
    { address: tx-sender }
    {
      base-score: (* BASE-REPUTATION u2),
      accuracy-score: MAX-ACCURACY-SCORE,
      total-predictions: u0,
      correct-predictions: u0,
      influence-multiplier: MAX-INFLUENCE-MULTIPLIER,
      last-updated: block-height,
      role: ROLE-ADMIN,
      active: true
    }
  )
)

# Quant -- Demo Questions (authored, with solutions)

These are **original GRE-style practice questions**, not official ETS questions. Use them to learn
the formats and the reasoning patterns. For official realism, do POWERPREP + ETS practice books.

Format legend:
- **QC** = Quantitative Comparison (A/B/C/D)
- **MC1** = Multiple Choice, one answer
- **MCN** = Multiple Choice, one or more
- **NE** = Numeric Entry

---

## Q1 (QC) -- Number properties
x is a nonzero integer.

  Quantity A:  x^2
  Quantity B:  x^3

**Answer: D**
**Why:** Try x = 2 -> A=4, B=8 (B greater). Try x = -2 -> A=4, B=-8 (A greater). Different outcomes
=> relationship cannot be determined. (D).
**Trap:** assuming x is positive.

---

## Q2 (QC) -- Percent / fractions
A shirt is marked up 25% from cost, then discounted 25% from the marked price.

  Quantity A:  The final price as a % of original cost
  Quantity B:  100%

**Answer: B**
**Why:** Let cost = 100. Marked = 125. Discount 25% off 125 = 125 * 0.75 = 93.75.
93.75% < 100%, so Quantity B is greater.
**Takeaway:** a% up then a% down always lands *below* the start (because the second % acts on a
larger base). Sequential percents are not symmetric.

---

## Q3 (MC1) -- Algebra / word problem
If 3 machines working at identical constant rates can produce 360 widgets in 2 hours, how long
(in hours) would it take 5 such machines to produce 900 widgets?

  (A) 2.0   (B) 2.5   (C) 3.0   (D) 4.0   (E) 5.0

**Answer: C (3.0 hours)**
**Why:** Rate per machine = 360 / (3 * 2) = 60 widgets/hour/machine.
5 machines -> 300 widgets/hour. Time for 900 = 900 / 300 = 3 hours.
**Takeaway:** rate problems: find the unit rate first (per machine per hour), then scale.

---

## Q4 (QC) -- Geometry / special triangles
In triangle ABC, angle A = 30 deg, angle B = 60 deg, and the side opposite angle B (AC) = 8 sqrt(3).

  Quantity A:  The length of side BC (opposite the 30 deg angle)
  Quantity B:  8

**Answer: C (the two quantities are equal)**
**Why:** In a 30-60-90 triangle the sides are in ratio 1 : sqrt(3) : 2.
The side opposite the 60 deg angle (AC) equals x * sqrt(3). Given AC = 8 sqrt(3), we get x = 8.
The side opposite the 30 deg angle (BC) equals x = 8. So Quantity A = 8 and Quantity B = 8.
**Lesson:** memorize 30-60-90 (1, sqrt3, 2) and 45-45-90 (1, 1, sqrt2) ratios cold.

---

## Q5 (MCN) -- Divisibility / primes
Which of the following MUST be true if n is a positive even integer? (select all that apply)

  A. n is divisible by 2
  B. n^2 is divisible by 4
  C. n is divisible by 6
  D. n(n+1) is divisible by 2

**Answer: A, B, D**
**Why:**
- A: definition of even. True.
- B: if n is even, n = 2k, so n^2 = 4k^2 -> divisible by 4. True.
- C: counterexample n = 2 (not divisible by 6). False.
- D: among two consecutive integers one is even, so the product is even. True (also true for odd n,
  but "must be true" only needs it to hold for all even n, which it does).
**Takeaway:** for "must be true," any single counterexample kills an option.

---

## Q6 (NE) -- Probability
A bag has 4 red, 3 blue, and 2 green marbles. If 2 marbles are drawn at random without replacement,
what is the probability that both are the same color? (Enter as a fraction.)

**Answer: 5/18**
**Why:** Total ways to choose 2 of 9 = C(9,2) = 36.
Favorable = both red C(4,2)=6, or both blue C(3,2)=3, or both green C(2,2)=1 -> 6+3+1 = 10.
Probability = 10/36 = 5/18.
**Takeaway:** "same color" = sum of each color's same-color pairs; use combinations C(n,2).

---

## Q7 (NE) -- Exponents / equations
If 2^(x) * 4^(x) = 1/8, what is x? (Enter as an integer or decimal.)

**Answer: -1**
**Why:** Rewrite with base 2: 4^x = (2^2)^x = 2^(2x). So 2^x * 2^(2x) = 2^(3x).
1/8 = 2^(-3). So 2^(3x) = 2^(-3) -> 3x = -3 -> x = -1.
**Takeaway:** unify bases; a^(mn) = (a^m)^n; a^-k = 1/a^k.

---

## Q8 (QC) -- Statistics / mean
Set S = {2, 4, 6, 8, 10}. Set T is formed by adding 3 to each element of S.

  Quantity A:  The average (arithmetic mean) of S
  Quantity B:  The average of T

**Answer: B**
**Why:** Adding a constant to every element adds that constant to the mean. Mean of S = 6; mean of
T = 6 + 3 = 9. So B (9) > A (6).
**Takeaway:** adding k shifts mean/median/mode by k; it does NOT shift range or SD (scaling does).

---

## Q9 (MC1) -- Word problem / mixture
How many liters of a 30% acid solution must be added to 4 liters of a 10% acid solution to make a
20% acid solution?

  (A) 2   (B) 3   (C) 4   (D) 5   (E) 6

**Answer: C (4 liters)**
**Why:** Let x = liters of 30% added. Acid: 0.30x + 0.10(4) = 0.20(x + 4).
0.30x + 0.4 = 0.20x + 0.8 -> 0.10x = 0.4 -> x = 4.
**Takeaway:** mixture equation: (concentration)(volume) summed = final concentration * total volume.

---

## Q10 (QC) -- Coordinate geometry
Line L passes through (0, 0) and (3, 4).

  Quantity A:  The slope of L
  Quantity B:  1

**Answer: A**
**Why:** slope = (4 - 0) / (3 - 0) = 4/3. Compare 4/3 vs 1 -> 4/3 > 1, so A is greater.
**Takeaway:** slope = rise/run = (y2 - y1)/(x2 - x1); a slope > 1 means steeper than 45 deg.

---

## Q11 (NE) -- Data interpretation reasoning
A store's revenue in 2023 was $120,000, a 20% increase over 2022. What was the 2022 revenue (in $)?

**Answer: 100000**
**Why:** 2023 = 1.20 * (2022) -> 2022 = 120000 / 1.20 = 100,000.
**Takeaway:** "% increase" makes the OLD value the base. To reverse: new / (1 + r). Do NOT subtract 20%.

---

## Q12 (QC) -- Inequalities
x > 1 and y > 1.

  Quantity A:  (x + y)^2
  Quantity B:  x^2 + y^2

**Answer: A**
**Why:** (x+y)^2 = x^2 + 2xy + y^2 = (x^2 + y^2) + 2xy. Since x,y > 1, 2xy > 0, so Quantity A is
strictly larger than Quantity B.
**Takeaway:** (a+b)^2 vs a^2 + b^2 differs by the cross term 2ab; its sign decides the comparison.

---

## How to use these
- Cover the solution, solve, then compare. Track which **type/concept** you miss (not just count).
- Re-do missed ones 3 days later (spaced repetition).
- Pair with official ETS questions weekly for calibrated difficulty.

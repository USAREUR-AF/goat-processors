package model

import "math"

// The two-model filter (spec/correlate.md: Two-model filter): two
// constant-velocity models, quiet and maneuver, combined as an interacting
// multiple model filter. Pure functions of the models and probabilities.

// ModelNames are the models by index (quiet = 1, maneuver = 2).
var ModelNames = [2]string{"quiet", "maneuver"}

// Maneuver is the pack's maneuver line.
type Maneuver struct {
	Var    float64 // q2, the maneuver model's acceleration variance
	PEnter float64 // a
	PLeave float64 // b
}

// Start is the long-run mode probabilities mu of a first report.
func (m Maneuver) Start() [2]float64 {
	s := m.PEnter + m.PLeave
	return [2]float64{m.PLeave / s, m.PEnter / s}
}

// Switching returns t[i][j], the probability of model j at the end of dt
// seconds given model i at its start (Switching).
func (m Maneuver) Switching(dt float64) [2][2]float64 {
	a, b := m.PEnter, m.PLeave
	s := a + b
	l := math.Pow(1-s, dt)
	t12 := a / s * (1 - l)
	t21 := b / s * (1 - l)
	return [2][2]float64{{1 - t12, t12}, {t21, 1 - t21}}
}

// Blend combines two axes with weights w1, w2 (step 1, step 5).
func Blend(w1, w2 float64, a1, a2 Axis) Axis {
	p := w1*a1.P + w2*a2.P
	v := w1*a1.V + w2*a2.V
	d1, e1, d2, e2 := a1.P-p, a1.V-v, a2.P-p, a2.V-v
	return Axis{
		P:  p,
		V:  v,
		PP: w1*(a1.PP+d1*d1) + w2*(a2.PP+d2*d2),
		PV: w1*(a1.PV+d1*e1) + w2*(a2.PV+d2*e2),
		VV: w1*(a1.VV+e1*e1) + w2*(a2.VV+e2*e2),
	}
}

// BlendModels combines two models with weights w1, w2.
func BlendModels(w1, w2 float64, m [2]Model) Model {
	return Model{Blend(w1, w2, m[0].East, m[1].East), Blend(w1, w2, m[0].North, m[1].North)}
}

// IMM is the state of the two-model filter: both models and their mode
// probabilities.
type IMM struct {
	Models [2]Model
	Mode   [2]float64
}

// IMMStep is the result of one update: the new state, the combined
// filter, and the log-likelihoods lambda of both models.
type IMMStep struct {
	IMM
	Combined Model
	Lambda   [2]float64
}

// Update applies one report dt seconds after the last: mixing,
// predict and update, likelihood, mode probabilities, combination
// (steps 1 to 5).
func (s IMM) Update(p FilterParams, m Maneuver, dt float64, z Measurement) IMMStep {
	models, mu := s.Models, s.Mode
	q := [2]float64{p.AccelVar, m.Var}
	tr := m.Switching(dt)

	// 1. Mixing.
	var c [2]float64
	var mixed [2]Model
	for j := 0; j < 2; j++ {
		c[j] = tr[0][j]*mu[0] + tr[1][j]*mu[1]
		if c[j] == 0 {
			mixed[j] = models[j]
			continue
		}
		w1, w2 := tr[0][j]*mu[0]/c[j], tr[1][j]*mu[1]/c[j]
		mixed[j] = BlendModels(w1, w2, models)
	}

	// 2. Predict and update, and 3. likelihood.
	var lambda [2]float64
	for j := 0; j < 2; j++ {
		var gj float64
		models[j], gj = p.Step(mixed[j], dt, q[j], z)
		lambda[j] = -0.5 * gj
	}

	// 4. Mode probabilities.
	mx := math.Inf(-1)
	for j := 0; j < 2; j++ {
		if c[j] > 0 && lambda[j] > mx {
			mx = lambda[j]
		}
	}
	var ev [2]float64
	for j := 0; j < 2; j++ {
		if c[j] > 0 {
			ev[j] = c[j] * math.Exp(lambda[j]-mx)
		}
	}
	sum := ev[0] + ev[1]
	mu = [2]float64{ev[0] / sum, ev[1] / sum}

	// 5. Combination.
	return IMMStep{IMM: IMM{models, mu}, Combined: BlendModels(mu[0], mu[1], models), Lambda: lambda}
}

// Predict is the combined prediction dt seconds ahead (Prediction).
func (s IMM) Predict(p FilterParams, m Maneuver, dt float64) Model {
	q := [2]float64{p.AccelVar, m.Var}
	var pr [2]Model
	for j := 0; j < 2; j++ {
		pr[j] = s.Models[j].Predict(dt, q[j])
	}
	return BlendModels(s.Mode[0], s.Mode[1], pr)
}

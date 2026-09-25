package main

import "testing"

func TestClosest(t *testing.T) {
	heard := []string{
		"грин готс",
		"грин готс сломался",
		"открой мейн точка гоу",
		"какие аргументы у метода где написано фанк",
	}

	for fixed, want := range map[string]string{
		"Gringotts":          "грин готс",
		"Gringotts сломался": "грин готс сломался",
		"открой main.go":     "открой мейн точка гоу",
		"какие аргументы у метода где написано func": "какие аргументы у метода где написано фанк",
	} {
		if got, score := closest(heard, fixed); got != want || score < minSimilarity {
			t.Errorf("closest(%q) = %q, %.2f; want %q", fixed, got, score, want)
		}
	}

	for _, unrelated := range []string{
		"func main() {",
		"Сегодня созвон переносится на завтра",
		"\tif err := saveCorrection(heard); err != nil {",
	} {
		if got, score := closest(heard, unrelated); score >= minSimilarity {
			t.Errorf("unrelated %q matched %q with %.2f", unrelated, got, score)
		}
	}

	if _, score := closest(nil, "text"); score != 0 {
		t.Errorf("closest with no transcripts scored %.2f", score)
	}
}

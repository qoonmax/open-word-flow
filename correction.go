package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"open-word-flow/paste"
	"open-word-flow/ui"
)

const (
	// recentTranscripts is how many transcripts Control+Fn can match a correction to.
	recentTranscripts = 10
	// minSimilarity separates a corrected transcript from unrelated text: fixes
	// such as "грин готс сломался" → "Gringotts сломался" score 0.5 and more,
	// unrelated sentences and code 0.1 to 0.4.
	// ponytail: fixed threshold, tune it on corrections.jsonl if it misfires.
	minSimilarity = 0.4
)

// Reasons a correction is not saved.
var (
	errNothingDictated = errors.New("nothing was dictated since the app started")
	errNothingSelected = errors.New("nothing is selected")
	errUnchanged       = errors.New("the selection is the transcript itself")
	errNoMatch         = errors.New("the selection is not like any recent transcript")
)

// latin spells Cyrillic in Latin letters for similarity.
var latin = strings.NewReplacer(
	"а", "a", "б", "b", "в", "v", "г", "g", "д", "d", "е", "e", "ё", "e", "ж", "zh",
	"з", "z", "и", "i", "й", "y", "к", "k", "л", "l", "м", "m", "н", "n", "о", "o",
	"п", "p", "р", "r", "с", "s", "т", "t", "у", "u", "ф", "f", "х", "h", "ц", "ts",
	"ч", "ch", "ш", "sh", "щ", "sch", "ъ", "", "ы", "y", "ь", "", "э", "e", "ю", "yu", "я", "ya",
)

// correct saves the corrected transcript selected in the focused app, as
// saveCorrection does, and shows the outcome in the indicator.
func correct(heard []string, last *[2]string) {
	ui.Correcting()

	pair, err := saveCorrection(heard, last)
	if err != nil {
		fmt.Fprintln(os.Stderr, "error: no correction saved:", err)
		ui.NotCorrected(reason(err))

		return
	}

	count, err := countCorrections()
	if err != nil {
		fmt.Fprintln(os.Stderr, "error: count corrections:", err)
	}

	fmt.Println("Correction saved.")
	ui.Corrected(count, pair[0], pair[1])
}

// reason explains err in the indicator, in English for ui to translate.
func reason(err error) string {
	switch {
	case errors.Is(err, errNothingDictated):
		return "Nothing dictated yet"
	case errors.Is(err, errNothingSelected):
		return "Nothing selected"
	case errors.Is(err, errUnchanged):
		return "Text unchanged"
	case errors.Is(err, errNoMatch):
		return "Not like a recent dictation"
	}

	return "Couldn't save"
}

// saveCorrection reads the text selected in the focused app, pairs it with the
// most similar of heard, and appends the pair to corrections.jsonl unless it
// equals last, the previously saved pair, which it then updates. It returns
// the pair: the transcript and its correction.
func saveCorrection(heard []string, last *[2]string) ([2]string, error) {
	if len(heard) == 0 {
		return [2]string{}, errNothingDictated
	}

	fixed, err := paste.Selection()
	if err != nil {
		return [2]string{}, err
	}

	fixed = strings.TrimSpace(fixed)
	if fixed == "" {
		return [2]string{}, errNothingSelected
	}

	original, score := closest(heard, fixed)
	if score < minSimilarity {
		return [2]string{}, fmt.Errorf("%w: %q", errNoMatch, fixed)
	}

	if original == fixed {
		return [2]string{}, errUnchanged
	}

	pair := [2]string{original, fixed}
	if pair == *last {
		return pair, nil // saved by an earlier press
	}

	path, err := correctionsFile()
	if err != nil {
		return [2]string{}, err
	}

	if err := appendCorrection(path, original, fixed); err != nil {
		return [2]string{}, err
	}

	*last = pair

	return pair, nil
}

// correctionsFile returns the path of corrections.jsonl.
func correctionsFile() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}

	return filepath.Join(dir, "Open Word Flow", "corrections.jsonl"), nil
}

// appendCorrection appends a transcript and the text it was corrected to as a
// JSON line to the file at path.
func appendCorrection(path, heard, fixed string) error {
	line, err := json.Marshal(struct {
		Time  time.Time `json:"time"`
		Heard string    `json:"heard"`
		Fixed string    `json:"fixed"`
	}{time.Now(), heard, fixed})
	if err != nil {
		return err
	}

	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}

	file, err := os.OpenFile(path, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		return err
	}

	if _, err := file.Write(append(line, '\n')); err != nil {
		_ = file.Close()

		return err
	}

	return file.Close()
}

// countCorrections returns how many corrections corrections.jsonl holds.
func countCorrections() (int, error) {
	path, err := correctionsFile()
	if err != nil {
		return 0, err
	}

	data, err := os.ReadFile(path)

	return bytes.Count(data, []byte("\n")), err
}

// closest returns the transcript most similar to fixed, preferring newer ones
// on a tie, and its similarity; the similarity is 0 when there are none.
func closest(transcripts []string, fixed string) (string, float64) {
	var best string

	bestScore := 0.0

	for i := len(transcripts) - 1; i >= 0; i-- {
		if score := similarity(transcripts[i], fixed); score > bestScore {
			best, bestScore = transcripts[i], score
		}
	}

	return best, bestScore
}

// similarity scores how alike a and b are, from 0 to 1, by edit distance.
// Case is ignored and Cyrillic is transliterated, so "грин готс" and its
// correction "Gringotts" still look alike.
func similarity(a, b string) float64 {
	ra := []rune(latin.Replace(strings.ToLower(a)))
	rb := []rune(latin.Replace(strings.ToLower(b)))

	longest := max(len(ra), len(rb))
	if longest == 0 {
		return 1
	}

	// Levenshtein distance, one row of the table at a time.
	row := make([]int, len(rb)+1)
	for j := range row {
		row[j] = j
	}

	for i := 1; i <= len(ra); i++ {
		diagonal := row[0]
		row[0] = i

		for j := 1; j <= len(rb); j++ {
			substitution := diagonal
			if ra[i-1] != rb[j-1] {
				substitution++
			}

			diagonal = row[j]
			row[j] = min(row[j]+1, row[j-1]+1, substitution)
		}
	}

	return 1 - float64(row[len(rb)])/float64(longest)
}

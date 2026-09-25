package ui

import "strings"

type (
	// segmentKind tells how a segment of a corrected text relates to the transcript.
	segmentKind int

	// segment is a run of words of a corrected text, as the indicator and
	// Settings show it.
	segment struct {
		Text string      `json:"text"`
		Kind segmentKind `json:"kind"`
	}
)

// Segment kinds; their numbers are part of the JSON the native code reads.
const (
	// kindKept words are in both the transcript and its correction.
	kindKept segmentKind = iota
	// kindRemoved words were replaced in the correction.
	kindRemoved
	// kindAdded words replaced removed ones.
	kindAdded
)

// contextWords is how many unchanged words diff keeps next to a change.
const contextWords = 3

// diff splits fixed into the words kept from heard and the words that
// replaced others. Each change lists the removed words before the added ones,
// and long unchanged stretches keep contextWords at the ends next to a
// change, joined by "…".
func diff(heard, fixed string) []segment {
	a, b := strings.Fields(heard), strings.Fields(fixed)

	// lcs[i][j] is the length of the longest common subsequence of a[i:] and b[j:].
	// ponytail: quadratic table, fine for dictation-sized texts.
	lcs := make([][]int, len(a)+1)
	for i := range lcs {
		lcs[i] = make([]int, len(b)+1)
	}

	for i := len(a) - 1; i >= 0; i-- {
		for j := len(b) - 1; j >= 0; j-- {
			if a[i] == b[j] {
				lcs[i][j] = lcs[i+1][j+1] + 1
			} else {
				lcs[i][j] = max(lcs[i+1][j], lcs[i][j+1])
			}
		}
	}

	var (
		segments             []segment
		kept, removed, added []string
	)

	emit := func(kind segmentKind, words *[]string) {
		if len(*words) > 0 {
			segments = append(segments, segment{Text: strings.Join(*words, " "), Kind: kind})
			*words = nil
		}
	}

	for i, j := 0, 0; i < len(a) || j < len(b); {
		switch {
		case i < len(a) && j < len(b) && a[i] == b[j]:
			emit(kindRemoved, &removed)
			emit(kindAdded, &added)

			kept = append(kept, a[i])
			i++
			j++
		case j == len(b) || (i < len(a) && lcs[i+1][j] >= lcs[i][j+1]):
			emit(kindKept, &kept)

			removed = append(removed, a[i])
			i++
		default:
			emit(kindKept, &kept)

			added = append(added, b[j])
			j++
		}
	}

	emit(kindKept, &kept)
	emit(kindRemoved, &removed)
	emit(kindAdded, &added)

	for i := range segments {
		if segments[i].Kind == kindKept {
			segments[i].Text = shorten(segments[i].Text, i > 0, i < len(segments)-1)
		}
	}

	return segments
}

// shorten keeps contextWords of text next to the changes before and after it.
func shorten(text string, before, after bool) string {
	words := strings.Fields(text)

	switch {
	case before && after && len(words) > 2*contextWords:
		return strings.Join(words[:contextWords], " ") + " … " + strings.Join(words[len(words)-contextWords:], " ")
	case before && !after && len(words) > contextWords:
		return strings.Join(words[:contextWords], " ") + " …"
	case !before && after && len(words) > contextWords:
		return "… " + strings.Join(words[len(words)-contextWords:], " ")
	}

	return text
}

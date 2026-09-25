package ui

import (
	"reflect"
	"testing"
)

func TestDiffWords(t *testing.T) {
	for _, test := range []struct {
		heard, fixed string
		want         []segment
	}{
		{
			"слушай, проверь логи в грин готс, там после деплоя всё падает",
			"слушай, проверь логи в Gringotts, там после деплоя всё падает",
			[]segment{
				{Text: "… проверь логи в", Kind: kindKept},
				{Text: "грин готс,", Kind: kindRemoved},
				{Text: "Gringotts,", Kind: kindAdded},
				{Text: "там после деплоя …", Kind: kindKept},
			},
		},
		{
			"допустим, technews, random, memos, location, Serbia",
			"допустим, tech-news, random, memes, location-serbia",
			[]segment{
				{Text: "допустим,", Kind: kindKept},
				{Text: "technews,", Kind: kindRemoved},
				{Text: "tech-news,", Kind: kindAdded},
				{Text: "random,", Kind: kindKept},
				{Text: "memos, location, Serbia", Kind: kindRemoved},
				{Text: "memes, location-serbia", Kind: kindAdded},
			},
		},
		{
			"открой мейн точка гоу",
			"открой main.go",
			[]segment{
				{Text: "открой", Kind: kindKept},
				{Text: "мейн точка гоу", Kind: kindRemoved},
				{Text: "main.go", Kind: kindAdded},
			},
		},
	} {
		if got := diff(test.heard, test.fixed); !reflect.DeepEqual(got, test.want) {
			t.Errorf("diff(%q, %q) =\n%+v\nwant\n%+v", test.heard, test.fixed, got, test.want)
		}
	}
}

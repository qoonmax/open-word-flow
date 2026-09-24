package main

import "testing"

func TestPrompt(t *testing.T) {
	got := prompt("  Kubernetes\n\nGitHub, pull request \n")
	if want := "Kubernetes, GitHub, pull request"; got != want {
		t.Fatalf("prompt = %q, want %q", got, want)
	}
}

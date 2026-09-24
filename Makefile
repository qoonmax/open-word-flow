# whisper.cpp is linked statically via cgo; these paths point at the build
# produced by `make whisper` in third_party/whisper.cpp/bindings/go.
WHISPER_DIR := $(abspath third_party/whisper.cpp)
BUILD_DIR   := $(WHISPER_DIR)/build_go
INFO_PLIST  := $(abspath Info.plist)

export C_INCLUDE_PATH := $(WHISPER_DIR)/include:$(WHISPER_DIR)/ggml/include
export LIBRARY_PATH   := $(BUILD_DIR)/src:$(BUILD_DIR)/ggml/src:$(BUILD_DIR)/ggml/src/ggml-blas:$(BUILD_DIR)/ggml/src/ggml-metal
# ggml loads its Metal shader library from here at runtime.
export GGML_METAL_PATH_RESOURCES := $(WHISPER_DIR)

APP_EXT_LDFLAGS := -Wl,-sectcreate,__TEXT,__info_plist,$(INFO_PLIST)
EXT_LDFLAGS := -framework Foundation -framework Metal -framework MetalKit -lggml-metal -lggml-blas $(APP_EXT_LDFLAGS)
GO_LDFLAGS := -ldflags "-extldflags '$(EXT_LDFLAGS)'"
GOLANGCI_LINT ?= golangci-lint
APP := build/Open Word Flow.app
MODELS := models/ggml-large-v3-turbo-q5_0.bin models/ggml-silero-v6.2.0.bin
# A stable identity keeps macOS permissions across rebuilds; "-" signs ad hoc,
# which makes macOS forget Accessibility access after every rebuild.
SIGN_IDENTITY ?= Apple Development
GOFMT_PATHS := main.go asr config hotkey paste recording ui

.PHONY: build app install run fmt-check vet test lint check quality whisper clean

build:
	go build $(GO_LDFLAGS) -o bin/open-word-flow .

# Bundles the binary and the models (APFS clones, no extra disk space) into a macOS app.
app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources/models"
	cp Info.plist "$(APP)/Contents/Info.plist"
	cp bin/open-word-flow "$(APP)/Contents/MacOS/open-word-flow"
	cp -c $(MODELS) "$(APP)/Contents/Resources/models/"
	codesign --force --sign "$(SIGN_IDENTITY)" "$(APP)"

install: app
	rm -rf "/Applications/Open Word Flow.app"
	ditto "$(APP)" "/Applications/Open Word Flow.app"

run: app
	open "$(APP)"

fmt-check:
	@unformatted="$$(gofmt -l $(GOFMT_PATHS))"; \
	if [ -n "$$unformatted" ]; then \
		echo "Files need gofmt:"; \
		echo "$$unformatted"; \
		exit 1; \
	fi

vet:
	go vet ./...

test:
	go test $(GO_LDFLAGS) ./...

lint:
	@command -v $(GOLANGCI_LINT) >/dev/null || { \
		echo "golangci-lint is required: https://golangci-lint.run/docs/welcome/install/"; \
		exit 1; \
	}
	$(GOLANGCI_LINT) run ./...

check: fmt-check vet test lint

quality: check

# (re)build the whisper.cpp static libraries
whisper:
	$(MAKE) -C $(WHISPER_DIR)/bindings/go whisper

clean:
	rm -rf bin build

# ---------------------------------------------------------------------------
# btTool —— 命令行构建脚本（不依赖 Xcode 界面，方便 CI / 快速验证）
#
#   make            # 编译并打包 build/btTool.app
#   make typecheck  # 只做类型检查（最快）
#   make run        # 构建后直接打开 App
#   make clean
#
# 说明：Xcode 工程里不需要这个 Makefile，二者任选其一。
# ---------------------------------------------------------------------------

APP_NAME   := btTool
SDK        ?= $(shell xcrun --show-sdk-path)
SOURCES    := $(shell find Sources -name '*.swift' | sort)
BUILD_DIR  := build
APP_DIR    := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS   := $(APP_DIR)/Contents
BINARY     := $(CONTENTS)/MacOS/$(APP_NAME)

.PHONY: all typecheck build run clean

all: build

typecheck:
	@echo "==> 类型检查 $(words $(SOURCES)) 个 Swift 文件"
	xcrun swiftc -typecheck -sdk $(SDK) \
		-framework AppKit -framework Carbon -framework ApplicationServices \
		$(SOURCES)

build:
	@echo "==> 构建 $(APP_DIR)"
	@rm -rf $(APP_DIR)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	xcrun swiftc -O -sdk $(SDK) \
		-framework AppKit -framework Carbon -framework ApplicationServices \
		$(SOURCES) -o $(BINARY)
	@sed -e 's/$$(DEVELOPMENT_LANGUAGE)/zh_CN/' \
	     -e 's/$$(EXECUTABLE_NAME)/$(APP_NAME)/' \
	     -e 's/$$(PRODUCT_BUNDLE_IDENTIFIER)/com.bttool.app/' \
	     -e 's/$$(PRODUCT_NAME)/$(APP_NAME)/' \
	     Resources/Info.plist > $(CONTENTS)/Info.plist
	@codesign --force --sign - --timestamp=none $(APP_DIR) 2>/dev/null || true
	@echo "==> 完成：$(APP_DIR)"

run: build
	@open $(APP_DIR)

clean:
	rm -rf $(BUILD_DIR)

# ---------------------------------------------------------------------------
# btTool —— 命令行构建脚本（不依赖 Xcode 界面，方便 CI / 快速验证）
#
#   make            # 编译并打包 build/btTool.app
#   make typecheck  # 只做类型检查（最快）
#   make run        # 构建后直接打开 App
#   make test       # 跑回归测试
#   make verify     # 自检构建产物（签名 / 最低系统 / 版本）
#   make dist       # 打分发用 zip（公证只收 zip / dmg / pkg）
#   make dmg        # 制作拖拽安装用 DMG
#   make notarize   # 公证 + 装订（需要 Developer ID，见该 target 注释）
#   make clean
#
# 说明：Xcode 工程里不需要这个 Makefile，二者任选其一。
# ---------------------------------------------------------------------------

APP_NAME   := btTool
SDK        ?= $(shell xcrun --show-sdk-path)
SOURCES    := $(shell find Sources -name '*.swift' | sort)
BUILD_DIR  := build
# 测试可执行文件 = 全部源码 **去掉 main.swift**（否则两个入口冲突）+ Tests/ 下的用例
LIB_SOURCES  := $(filter-out Sources/Application/main.swift,$(SOURCES))
TEST_SOURCES := $(shell find Tests -name '*.swift' | sort)
TEST_BINARY  := $(BUILD_DIR)/btToolTests
APP_DIR    := $(BUILD_DIR)/$(APP_NAME).app
CONTENTS   := $(APP_DIR)/Contents
BINARY     := $(CONTENTS)/MacOS/$(APP_NAME)

# 🎯 部署目标：macOS 11.0
#
#    依据是**代码实际用到的 API**，不是拍脑袋：`NSImage(systemSymbolName:)` 自 macOS 11 起才有。
#    ⚠️ Info.plist 里原本写的是 10.15 —— 与实际依赖不符，在 10.15 上会直接
#       「Symbol not found」崩在启动阶段。现在 Info.plist 与 -target 取同一个值。
DEPLOYMENT_TARGET ?= 11.0

# 🎯 架构：默认**只构建 x86_64**
#
#    Touch Bar 是 Intel Mac（2016–2020）独有的硬件：Apple Silicon 上没有 TouchBarServer，
#    连 DFR 这套私有 API 都不存在 —— 本工具在那里只能走「不支持，降级为日志」分支。
#    所以 arm64 切片对我们没有用处，只会让体积翻倍。
#    确有需要时：make build ARCH=universal（分别编译两个切片再用 lipo 合并）
ARCH ?= x86_64

# 类型检查 / 测试只跑单一架构就够了；universal 时取 x86_64
BUILD_ARCH   := $(if $(filter universal,$(ARCH)),x86_64,$(ARCH))
SWIFT_TARGET := $(BUILD_ARCH)-apple-macosx$(DEPLOYMENT_TARGET)

X86_TARGET := x86_64-apple-macosx$(DEPLOYMENT_TARGET)
ARM_TARGET := arm64-apple-macosx$(DEPLOYMENT_TARGET)

# 版本号从 Info.plist 读，避免多处写死后各说各话
VERSION  := $(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || echo 1.0)
DIST_ZIP := $(BUILD_DIR)/$(APP_NAME)-$(VERSION)-$(ARCH).zip
DIST_DMG := $(BUILD_DIR)/$(APP_NAME)-$(VERSION)-$(ARCH).dmg

# 🔏 签名身份：默认 ad-hoc（-）。要公证就得换成 Developer ID，见 notarize。
SIGN_IDENTITY ?= -

# 公证凭证在钥匙串里的名字
NOTARY_PROFILE ?= btTool

# Swift 共用编译参数
SWIFT_FLAGS := -O -sdk $(SDK) -framework AppKit -framework Carbon -framework ApplicationServices

# 🔬 Hardened Runtime 开关
#      P0 实测结论：与托盘显示**无关** —— A（关）/C（开）两种配置下图标都可见。
#      make build                → 带 --options runtime（默认）
#      make build HARDENED=0     → 不带
HARDENED ?= 1
ifeq ($(HARDENED),1)
CODESIGN_OPTIONS = --options runtime
else
CODESIGN_OPTIONS =
endif

.PHONY: all typecheck build run test verify dist dmg notarize notary-profile icon clean

all: build

typecheck:
	@echo "==> 类型检查 $(words $(SOURCES)) 个 Swift 文件（macOS $(DEPLOYMENT_TARGET)+）"
	xcrun swiftc -typecheck -sdk $(SDK) -target $(SWIFT_TARGET) \
		-framework AppKit -framework Carbon -framework ApplicationServices \
		$(SOURCES)

build:
	@echo "==> 构建 $(APP_DIR)（arch=$(ARCH)，macOS $(DEPLOYMENT_TARGET)+）"
	@rm -rf $(APP_DIR)
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
ifeq ($(ARCH),universal)
	@echo "    → 编译 x86_64 切片"
	xcrun swiftc $(SWIFT_FLAGS) -target $(X86_TARGET) $(SOURCES) -o $(BINARY).x86_64
	@echo "    → 编译 arm64 切片"
	xcrun swiftc $(SWIFT_FLAGS) -target $(ARM_TARGET) $(SOURCES) -o $(BINARY).arm64
	@lipo -create -output $(BINARY) $(BINARY).x86_64 $(BINARY).arm64
	@rm -f $(BINARY).x86_64 $(BINARY).arm64
else
	xcrun swiftc $(SWIFT_FLAGS) -target $(SWIFT_TARGET) $(SOURCES) -o $(BINARY)
endif
	@sed -e 's/$$(DEVELOPMENT_LANGUAGE)/zh_CN/' \
	     -e 's/$$(EXECUTABLE_NAME)/$(APP_NAME)/' \
	     -e 's/$$(PRODUCT_BUNDLE_IDENTIFIER)/com.bttool.app/' \
	     -e 's/$$(PRODUCT_NAME)/$(APP_NAME)/' \
	     Resources/Info.plist > $(CONTENTS)/Info.plist
	@cp Resources/AppIcon.icns $(CONTENTS)/Resources/AppIcon.icns
	@echo "    → 签名身份：$(SIGN_IDENTITY)"
	@codesign --force $(CODESIGN_OPTIONS) --sign "$(SIGN_IDENTITY)" --timestamp=none \
	          $(APP_DIR) 2>/dev/null \
	  || echo "⚠️ 签名失败，App 可能无法启动：去掉上面的 2>/dev/null 看完整报错"
	@lipo -info $(BINARY) | sed 's/^/    /'
	@echo "==> 完成：$(APP_DIR)"

run: build
	@open $(APP_DIR)

# 测试**不加 -target**：断言都是纯逻辑、与架构无关，用本机架构编译才能直接执行
#     —— 在 Apple Silicon 的 CI runner 上编出 x86_64 测试二进制还得先装 Rosetta。
#     目标架构到底能不能编译，由 `typecheck`（带 -target）负责验证。
test:
	@echo "==> 构建并运行测试（本机架构）"
	@mkdir -p $(BUILD_DIR)
	xcrun swiftc -O -sdk $(SDK) \
		-framework AppKit -framework Carbon -framework ApplicationServices \
		$(LIB_SOURCES) $(TEST_SOURCES) -o $(TEST_BINARY)
	@$(TEST_BINARY)

# 🔍 分发前的自检：省得把不合格的包发出去
verify: build
	@echo "==> 验证构建产物"
	@codesign --verify --verbose=2 $(APP_DIR) 2>&1 | sed 's/^/    /'
	@codesign -dv --verbose=4 $(APP_DIR) 2>&1 | grep -E "Identifier=|TeamIdentifier=|Runtime|Flags=" | sed 's/^/    /'
	@echo "    最低系统：$(shell /usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' $(CONTENTS)/Info.plist)"
	@echo "    版本：$(shell /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' $(CONTENTS)/Info.plist)"

# 📦 分发包：公证只收 zip / dmg / pkg，不能直接提交 .app
#    --keepParent 保证解压后重新得到 btTool.app，而不是一堆散文件
dist: build
	@echo "==> 打分发包"
	@rm -f $(DIST_ZIP)
	@ditto -c -k --keepParent $(APP_DIR) $(DIST_ZIP)
	@echo "    $(DIST_ZIP)"
	@du -h $(DIST_ZIP) | cut -f1 | sed 's/^/    体积：/'

# 📀 DMG 安装镜像：打开后把 App 拖到“应用程序”即可
dmg: build
	@echo "==> 制作 DMG 安装镜像"
	@staging=$$(mktemp -d); \
	  trap 'rm -rf "$$staging"' EXIT; \
	  ditto "$(APP_DIR)" "$$staging/$(APP_NAME).app"; \
	  ln -s /Applications "$$staging/Applications"; \
	  hdiutil create -volname "$(APP_NAME)" -srcfolder "$$staging" \
	    -ov -format UDZO "$(DIST_DMG)"
	@echo "    $(DIST_DMG)"

# 🎨 生成应用图标
#
#    为什么不用 AI 生成的图：图像生成模型会在输出图右下角**打水印**（不能当图标用），
#    而且渐变/噪点让 PNG 压不动（1.6M）。这里改为 CoreGraphics 程序化绘制纯色块：
#    无水印、体积降到几十 KB，改配色只需编辑 Scripts/MakeIcon.swift 再跑一次。
icon:
	@echo "==> 生成应用图标"
	@mkdir -p $(BUILD_DIR)
	xcrun swiftc -O -sdk $(SDK) -framework CoreGraphics -framework ImageIO \
		Scripts/MakeIcon.swift -o $(BUILD_DIR)/make-icon
	@$(BUILD_DIR)/make-icon

# 🔐 公证 + 装订
#
#    公证要三样东西，缺一不可 —— 所以先做前置检查、缺什么就直说，
#    而不是把 notarytool 的原始报错甩出来让人猜：
#      ① Developer ID Application 证书（本机目前 0 个，所以这一步默认跑不通）
#      ② 钥匙串里的公证凭证（一次性 App 专用密码，见 make notary-profile）
#      ③ App 本身用 Developer ID 签名 —— ad-hoc 的 `-` 过不了公证
notarize: dist
	@echo "==> 公证前置检查"
ifeq ($(SIGN_IDENTITY),-)
	@echo "❌ 当前是 ad-hoc 签名（--sign -），公证不接受。"
	@echo "   先查到你的 Developer ID 证书名，然后这样跑："
	@echo "     make clean && make notarize SIGN_IDENTITY=\"Developer ID Application: 你的名字 (TEAMID)\""
	@exit 1
endif
	@security find-identity -v -p codesigning | grep -q "Developer ID Application" \
	  || { echo "❌ 钥匙串里没有 Developer ID Application 证书。"; \
	       echo "   Xcode → Settings → Accounts 添加开发者账号后下载该证书。"; exit 1; }
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1 \
	  || { echo "❌ 钥匙串里没有名为「$(NOTARY_PROFILE)」的公证凭证，先跑：make notary-profile"; exit 1; }
	@echo "    ✓ 三项前置都通过"
	@echo "==> 提交公证（--wait 会等到出结果，通常几十秒）"
	xcrun notarytool submit $(DIST_ZIP) --keychain-profile "$(NOTARY_PROFILE)" --wait
	@echo "==> 装订票据到 App（staple：没网也能被 Gatekeeper 放行）"
	xcrun stapler staple $(APP_DIR)
	@echo "==> 重打分发包（含票据）"
	@# ⚠️ 只能**重新打包**，不能再 make dist —— 那会重新 build，
	@#    覆盖掉刚装订好票据的 App，票据就没了。
	@rm -f $(DIST_ZIP)
	@ditto -c -k --keepParent $(APP_DIR) $(DIST_ZIP)
	@echo "==> 公证完成：$(DIST_ZIP)"

# 把公证凭证存进钥匙串（每台机器只需一次）
# 不用交互式 read：Makefile 的 shell 不保证支持 `read -s`，直接把命令摆出来更稳
notary-profile:
	@echo "==> 存公证凭证到钥匙串（每台机器一次）："
	@echo ""
	@echo "      xcrun notarytool store-credentials $(NOTARY_PROFILE) \\"
	@echo "          --apple-id <你的AppleID> \\"
	@echo "          --team-id <TeamID> \\"
	@echo "          --password <App专用密码>"
	@echo ""
	@echo "    password 是 App 专用密码（appleid.apple.com 生成），**不是** Apple ID 密码。"
	@echo "    Team ID 在 developer.apple.com/account 的 Membership 页可以看到。"

clean:
	rm -rf $(BUILD_DIR)

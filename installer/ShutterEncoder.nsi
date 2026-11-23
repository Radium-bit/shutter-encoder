; Shutter Encoder noPrompt 版安装脚本。
; 由 build-noPrompt.ps1 调用，通过 /D 传入 APP_VERSION、APP_IMAGE、OUTPUT_DIR。
; 安装布局与官方 jpackage 安装包一致：安装根目录下放 app 与 runtime 两个子目录。

Unicode true

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

!define PRODUCT_NAME "Shutter Encoder"
!define PRODUCT_PUBLISHER "Shutter Encoder noPrompt build"
!define PRODUCT_EXE "Shutter Encoder.exe"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\ShutterEncoderNoPrompt"

!ifndef APP_VERSION
  !error "APP_VERSION 未定义，请通过构建脚本传入。"
!endif
!ifndef APP_IMAGE
  !error "APP_IMAGE 未定义，请通过构建脚本传入。"
!endif
!ifndef OUTPUT_DIR
  !error "OUTPUT_DIR 未定义，请通过构建脚本传入。"
!endif

Name "${PRODUCT_NAME} ${APP_VERSION}"
OutFile "${OUTPUT_DIR}\ShutterEncoder-${APP_VERSION}-Setup.exe"
InstallDir "$PROGRAMFILES64\${PRODUCT_NAME}"
InstallDirRegKey HKLM "Software\${PRODUCT_NAME}" "InstallDir"
RequestExecutionLevel admin
SetCompressor /SOLID lzma
ShowInstDetails show
ShowUninstDetails show

VIProductVersion "20.5.0.0"
VIAddVersionKey "ProductName" "${PRODUCT_NAME}"
VIAddVersionKey "ProductVersion" "${APP_VERSION}"
VIAddVersionKey "FileVersion" "${APP_VERSION}"
VIAddVersionKey "FileDescription" "${PRODUCT_NAME} 安装程序"
VIAddVersionKey "LegalCopyright" "GNU General Public License v2"

!define MUI_ABORTWARNING
!define MUI_ICON "${NSISDIR}\Contrib\Graphics\Icons\modern-install.ico"
!define MUI_UNICON "${NSISDIR}\Contrib\Graphics\Icons\modern-uninstall.ico"

!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

!insertmacro MUI_LANGUAGE "English"
!insertmacro MUI_LANGUAGE "SimpChinese"

; 安装前结束正在运行的实例，否则文件被占用会导致覆盖失败。
Function .onInit
  SetRegView 64
  nsExec::Exec 'taskkill /F /IM "${PRODUCT_EXE}"'
  Pop $0
FunctionEnd

Section "Install"
  SetShellVarContext all
  SetRegView 64
  SetOutPath "$INSTDIR"
  SetOverwrite on

  ; 应用镜像已包含 app（jar、Languages、Library、LUTs）与 runtime 两棵子树。
  File /r "${APP_IMAGE}\*.*"

  ; 卸载程序与注册表项
  WriteUninstaller "$INSTDIR\uninstall.exe"

  WriteRegStr HKLM "Software\${PRODUCT_NAME}" "InstallDir" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayName" "${PRODUCT_NAME}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayVersion" "${APP_VERSION}"
  WriteRegStr HKLM "${UNINST_KEY}" "Publisher" "${PRODUCT_PUBLISHER}"
  WriteRegStr HKLM "${UNINST_KEY}" "DisplayIcon" "$INSTDIR\${PRODUCT_EXE}"
  WriteRegStr HKLM "${UNINST_KEY}" "InstallLocation" "$INSTDIR"
  WriteRegStr HKLM "${UNINST_KEY}" "UninstallString" '"$INSTDIR\uninstall.exe"'
  WriteRegStr HKLM "${UNINST_KEY}" "QuietUninstallString" '"$INSTDIR\uninstall.exe" /S'
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoModify" 1
  WriteRegDWORD HKLM "${UNINST_KEY}" "NoRepair" 1

  ; 记录安装体积，供控制面板显示
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" "$0"

  ; 快捷方式
  CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
  CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_EXE}"
  CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\卸载 ${PRODUCT_NAME}.lnk" "$INSTDIR\uninstall.exe"
  CreateShortCut "$DESKTOP\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_EXE}"

  ; 关联文件类型，与官方安装包保持一致
  WriteRegStr HKCR ".enc" "" "ShutterEncoder.Preset"
  WriteRegStr HKCR "ShutterEncoder.Preset" "" "Shutter Encoder preset"
  WriteRegStr HKCR "ShutterEncoder.Preset\DefaultIcon" "" "$INSTDIR\${PRODUCT_EXE},0"
  WriteRegStr HKCR "ShutterEncoder.Preset\shell\open\command" "" '"$INSTDIR\${PRODUCT_EXE}" "%1"'
SectionEnd

Section "Uninstall"
  SetShellVarContext all
  SetRegView 64
  nsExec::Exec 'taskkill /F /IM "${PRODUCT_EXE}"'

  Delete "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk"
  Delete "$SMPROGRAMS\${PRODUCT_NAME}\卸载 ${PRODUCT_NAME}.lnk"
  RMDir "$SMPROGRAMS\${PRODUCT_NAME}"
  Delete "$DESKTOP\${PRODUCT_NAME}.lnk"

  DeleteRegKey HKLM "${UNINST_KEY}"
  DeleteRegKey HKLM "Software\${PRODUCT_NAME}"
  DeleteRegKey HKCR "ShutterEncoder.Preset"

  RMDir /r "$INSTDIR"

  ; 用户配置目录保留，避免卸载时丢失预设与设置，需用户手动清理。
SectionEnd

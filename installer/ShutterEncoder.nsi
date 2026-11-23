; Installer script for the Shutter Encoder noPrompt build.
; Invoked by build-noPrompt.ps1, which passes APP_VERSION, APP_IMAGE and OUTPUT_DIR via /D.
; The layout matches the official jpackage installer: app and runtime live under the install root.

Unicode true

!include "MUI2.nsh"
!include "FileFunc.nsh"
!include "LogicLib.nsh"

!define PRODUCT_NAME "Shutter Encoder"
!define PRODUCT_PUBLISHER "Shutter Encoder noPrompt build"
!define PRODUCT_EXE "Shutter Encoder.exe"
!define UNINST_KEY "Software\Microsoft\Windows\CurrentVersion\Uninstall\ShutterEncoderNoPrompt"

!ifndef APP_VERSION
  !error "APP_VERSION is not defined; pass it from the build script."
!endif
!ifndef APP_IMAGE
  !error "APP_IMAGE is not defined; pass it from the build script."
!endif
!ifndef OUTPUT_DIR
  !error "OUTPUT_DIR is not defined; pass it from the build script."
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
VIAddVersionKey "FileDescription" "${PRODUCT_NAME} setup"
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

; Terminate a running instance first, otherwise locked files break the overwrite.
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

  ; The app image already contains the app subtree (jar, Languages, Library, LUTs)
  ; and the runtime subtree.
  File /r "${APP_IMAGE}\*.*"

  ; Uninstaller and registry entries
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

  ; Record the installed size for the Programs and Features column
  ${GetSize} "$INSTDIR" "/S=0K" $0 $1 $2
  IntFmt $0 "0x%08X" $0
  WriteRegDWORD HKLM "${UNINST_KEY}" "EstimatedSize" "$0"

  ; Shortcuts
  CreateDirectory "$SMPROGRAMS\${PRODUCT_NAME}"
  CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_EXE}"
  CreateShortCut "$SMPROGRAMS\${PRODUCT_NAME}\Uninstall ${PRODUCT_NAME}.lnk" "$INSTDIR\uninstall.exe"
  CreateShortCut "$DESKTOP\${PRODUCT_NAME}.lnk" "$INSTDIR\${PRODUCT_EXE}"

  ; File type association, matching the official installer
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
  Delete "$SMPROGRAMS\${PRODUCT_NAME}\Uninstall ${PRODUCT_NAME}.lnk"
  RMDir "$SMPROGRAMS\${PRODUCT_NAME}"
  Delete "$DESKTOP\${PRODUCT_NAME}.lnk"

  DeleteRegKey HKLM "${UNINST_KEY}"
  DeleteRegKey HKLM "Software\${PRODUCT_NAME}"
  DeleteRegKey HKCR "ShutterEncoder.Preset"

  RMDir /r "$INSTDIR"

  ; The user configuration directory is kept so presets and settings survive
  ; an uninstall; removing it is left to the user.
SectionEnd

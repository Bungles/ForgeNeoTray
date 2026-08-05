#Requires AutoHotkey v2.0
#SingleInstance Force

; bump this on every release - it's how ForgeNeoTray checks its own GitHub releases
; for updates, separate from checking Forge Neo itself
ForgeNeoTrayVersion := "1.5"
ForgeNeoTrayGitHubRepo := "Bungles/ForgeNeoTray"

try DllCall("SetProcessDpiAwarenessContext", "ptr", -4, "int")
Persistent()
OnError(LogError)
OnMessage(0x404, TrayNotifyMessageHandler)

; 0x405 = NIN_BALLOONUSERCLICK - clicked the notification body itself, not the icon.
; two different TrayTips are possible now, so check both pending flags
TrayNotifyMessageHandler(wParam, lParam, msg, hwnd) {
    global PendingUpdateStatus, PendingSelfUpdateVersion
    if (lParam != 0x405)
        return
    if PendingSelfUpdateVersion != "" {
        PendingSelfUpdateVersion := ""
        Run("https://github.com/" ForgeNeoTrayGitHubRepo "/releases/latest")
        return
    }
    if TryFocusExistingUpdateFlow()
        return
    if IsObject(PendingUpdateStatus) {
        status := PendingUpdateStatus
        PendingUpdateStatus := 0
        choice := ShowUpdateAvailableDialog(status.message, status.target)
        if choice.proceed
            ApplyUpdate(status.target, status.displayTarget)
    } else {
        CheckForUpdates()
    }
}

LogError(err, *) {
    logPath := A_ScriptDir "\ForgeNeoTray_error.log"
    FileAppend(A_Now " - " err.Message " (line " err.Line ", " err.What ")`n", logPath)
    TrimLogFile(logPath, 500)
    MsgBox("ForgeNeoTray hit an error:`n" err.Message "`n`nLogged to:`n" logPath)
    return true
}

TrimLogFile(path, maxLines) {
    try {
        content := FileRead(path)
    } catch {
        return
    }
    lines := StrSplit(content, "`n")
    if lines.Length <= maxLines
        return
    startIdx := lines.Length - maxLines + 1
    trimmed := ""
    loop maxLines {
        trimmed .= lines[startIdx + A_Index - 1] "`n"
    }
    try {
        FileDelete(path)
        FileAppend(trimmed, path)
    } catch {
        ; best-effort log maintenance - a failure here (locked file, permissions,
        ; etc.) shouldn't interrupt anything the user is actually doing
    }
}

; ============ Settings ============
SettingsPath := A_ScriptDir "\ForgeNeoTray_settings.ini"
isFirstRun := !FileExist(SettingsPath)

if isFirstRun {
    if !FileExist(A_ScriptDir "\webui-user.bat") {
        FirstRunSetup()
        return
    }
    IniWrite(A_ScriptDir, SettingsPath, "Settings", "ForgeNeoDir")
    IniWrite("webui-user.bat", SettingsPath, "Settings", "ForgeNeoBat")
    IniWrite("http://127.0.0.1:7860", SettingsPath, "Settings", "ForgeNeoURL")
    IniWrite(0, SettingsPath, "Settings", "HideConsoleOnLaunch")
    IniWrite(0, SettingsPath, "Settings", "StartupDelaySeconds")
    IniWrite("release", SettingsPath, "Settings", "UpdateMode")
    IniWrite(0, SettingsPath, "Settings", "CheckUpdatesOnLaunch")
    IniWrite(0, SettingsPath, "Settings", "EnableExtensionsUpdater")
    IniWrite("browser", SettingsPath, "Settings", "DoubleClickAction")
    IniWrite(200, SettingsPath, "Settings", "DoubleClickIntervalMs")
    IniWrite(1, SettingsPath, "Settings", "CheckSelfUpdatesOnLaunch")
}

InitRuntimeGlobals()
CheckStartupRegistryOnLaunch()

if isFirstRun
    ShowCenteredNotice("Forge Neo Tray", "Found webui-user.bat — launching Forge Neo now.`n`nRight-click the tray icon anytime to open Settings, including if you ever move this program to a different folder later.", true)
; ===================================

; loads settings into globals, sets up runtime state. called from both startup paths
; so Settings works even from the first-run notice
InitRuntimeGlobals() {
    global SettingsPath, ForgeNeoDir, ForgeNeoBat, ForgeNeoURL, HideConsoleOnLaunch, StartupDelaySeconds
    global RunKeyName, RunKeyPath, ForgePID, clickPending, SettingsGuiRef, SuppressCrashNotice, PendingSettingsAlwaysOnTop, SuppressStartupWrite, PendingUpdateStatus, UpdateFlowGuiRef, PendingSelfUpdateVersion
    global UpdateMode, CheckUpdatesOnLaunch, EnableExtensionsUpdater, DoubleClickAction, DoubleClickIntervalMs, CheckSelfUpdatesOnLaunch

    ForgeNeoDir := IniRead(SettingsPath, "Settings", "ForgeNeoDir", A_ScriptDir)
    ForgeNeoBat := IniRead(SettingsPath, "Settings", "ForgeNeoBat", "webui-user.bat")
    ForgeNeoURL := IniRead(SettingsPath, "Settings", "ForgeNeoURL", "http://127.0.0.1:7860")
    HideConsoleOnLaunch := Integer(IniRead(SettingsPath, "Settings", "HideConsoleOnLaunch", "1"))
    StartupDelaySeconds := Integer(IniRead(SettingsPath, "Settings", "StartupDelaySeconds", "0"))
    UpdateMode := IniRead(SettingsPath, "Settings", "UpdateMode", "release")
    CheckUpdatesOnLaunch := Integer(IniRead(SettingsPath, "Settings", "CheckUpdatesOnLaunch", "0"))
    EnableExtensionsUpdater := Integer(IniRead(SettingsPath, "Settings", "EnableExtensionsUpdater", "0"))
    DoubleClickAction := IniRead(SettingsPath, "Settings", "DoubleClickAction", "browser")
    DoubleClickIntervalMs := Integer(IniRead(SettingsPath, "Settings", "DoubleClickIntervalMs", "200"))
    CheckSelfUpdatesOnLaunch := Integer(IniRead(SettingsPath, "Settings", "CheckSelfUpdatesOnLaunch", "1"))
    RunKeyName := "ForgeNeoTray"
    RunKeyPath := "HKCU\Software\Microsoft\Windows\CurrentVersion\Run"

    DetectHiddenWindows(true)
    SetTitleMatchMode(2)
    ForgePID := 0
    clickPending := false
    SettingsGuiRef := 0
    SuppressCrashNotice := false
    PendingSettingsAlwaysOnTop := false
    SuppressStartupWrite := false
    PendingUpdateStatus := 0
    PendingSelfUpdateVersion := ""
    UpdateFlowGuiRef := 0
}

StartForgeAndTray()

; no Reload() here on purpose - kills a Settings window if one's open
StartForgeAndTray() {
    global StartupDelaySeconds, CheckUpdatesOnLaunch, CheckSelfUpdatesOnLaunch
    if StartupDelaySeconds > 0
        SetTimer(LaunchForge, -(StartupDelaySeconds * 1000))
    else
        LaunchForge()
    SetTrayIcon()
    SetTimer(CheckForgeStatus, 5000)
    SetTimer(SetTrayIcon, 60000)
    if CheckUpdatesOnLaunch
        SetTimer(CheckUpdatesSilently, -5000)
    if CheckSelfUpdatesOnLaunch
        SetTimer(CheckForgeNeoTrayUpdateSilently, -7000)
}

; catches a startup entry pointing at a different copy of the exe (multiple install
; locations, testing, etc)
CheckStartupRegistryOnLaunch() {
    global SuppressStartupWrite
    existingPath := GetStartupRegistryPath()
    if existingPath = "" || existingPath = A_ScriptFullPath
        return
    choice := ShowRepointStartupDialog(existingPath)
    if choice.rewrite
        SetStartupState(true)
    else
        SuppressStartupWrite := true
}

ClearStartupSuppress(*) {
    global SuppressStartupWrite
    SuppressStartupWrite := false
}

TrayClickHandler(*) {
    global clickPending, DoubleClickIntervalMs
    if clickPending {
        clickPending := false
        SetTimer(DoSingleClick, 0)
        PerformDoubleClickAction()
    } else {
        clickPending := true
        SetTimer(DoSingleClick, -DoubleClickIntervalMs)
    }
}

; dispatches based on the configured double-click action, defaults to browser
; shared index-to-value mapping for the double-click dropdown
GetDoubleClickOptionValues() {
    return ["browser", "recentoutput", "savedimages", "installfolder", "models"]
}

PerformDoubleClickAction() {
    global ForgeNeoDir, DoubleClickAction
    switch DoubleClickAction {
        case "savedimages":
            OpenFolderPath(GetForgeSaveDir())
        case "installfolder":
            OpenFolderPath(ForgeNeoDir)
        case "models":
            OpenFolderPath(ForgeNeoDir "\models")
        case "recentoutput":
            folder := GetMostRecentOutputFolder()
            if folder != ""
                OpenFolderPath(folder)
            else
                ShowCenteredNotice("Forge Neo Tray", "No output folders found yet.")
        default:
            OpenBrowser()
    }
}

; checks whichever output folder(s) are actually in play (the single shared one if
; set, otherwise both txt2img and img2img) and returns the single most recent dated
; subfolder across them, comparing date-folder names directly since YYYY-MM-DD sorts
; correctly as plain strings
GetMostRecentOutputFolder() {
    candidates := []
    sharedDir := GetForgeSharedOutputDir()
    if sharedDir != ""
        candidates.Push(sharedDir)
    else {
        candidates.Push(GetForgeOutputDir("txt2img"))
        candidates.Push(GetForgeOutputDir("img2img"))
    }
    bestFolder := ""
    bestDate := ""
    for dir in candidates {
        dates := GetDateSubfolders(dir)
        if dates.Length = 0
            continue
        if bestFolder = "" || dates[1] > bestDate {
            bestDate := dates[1]
            bestFolder := dir "\" dates[1]
        }
    }
    if bestFolder != ""
        return bestFolder
    return candidates.Length > 0 ? candidates[1] : ""
}

DoSingleClick() {
    global clickPending
    clickPending := false
    ToggleConsole()
}

ToggleConsole(*) {
    hwnd := WinExist("ForgeNeoConsole")
    if !hwnd
        return
    if DllCall("IsWindowVisible", "ptr", hwnd)
        WinHide()
    else {
        WinShow()
        WinActivate()
    }
}

CheckForgeStatus() {
    global ForgePID, SuppressCrashNotice
    if (ForgePID && !SuppressCrashNotice && !ProcessExist(ForgePID)) {
        TrayTip("The Forge Neo process appears to have stopped unexpectedly.", "Forge Neo", 2)
        ForgePID := 0
    }
}

SetTrayIcon() {
    A_IconTip := "Forge Neo"
    A_TrayMenu.Delete()
    A_TrayMenu.Add("Show/Hide Console", TrayClickHandler)
    A_TrayMenu.Add("Launch in Browser", OpenBrowser)

    OpenMenu := Menu()
    OpenMenu.Add("Install Folder", OpenInstallFolder)
    AddFolderMenuItem(OpenMenu, "Models", ForgeNeoDir "\models")
    OpenMenu.Add("Saved Images", MakeOpenFolderCallback(GetForgeSaveDir()))
    sharedOutputDir := GetForgeSharedOutputDir()
    if sharedOutputDir != "" {
        AddFolderMenuItem(OpenMenu, "Output", sharedOutputDir, false)
    } else {
        AddFolderMenuItem(OpenMenu, "txt2img output", GetForgeOutputDir("txt2img"), false)
        AddFolderMenuItem(OpenMenu, "img2img output", GetForgeOutputDir("img2img"), false)
    }
    OpenMenu.Add()
    OpenMenu.Add("Refresh", (*) => SetTrayIcon())
    A_TrayMenu.Add("Open...", OpenMenu)

    A_TrayMenu.Add()
    A_TrayMenu.Add("Settings", OpenSettingsWindow)
    A_TrayMenu.Add()
    if EnableExtensionsUpdater {
        UpdateMenu := Menu()
        UpdateMenu.Add("SD Forge Neo", CheckForUpdates)

        ExtMenu := Menu()
        ExtMenu.Add("Update All", UpdateAllExtensions)
        ExtMenu.Add()
        for extName in GetGitExtensionFolders()
            ExtMenu.Add(extName, MakeUpdateExtensionCallback(extName))
        UpdateMenu.Add("Extensions", ExtMenu)

        A_TrayMenu.Add("Check for Updates", UpdateMenu)
    } else {
        A_TrayMenu.Add("Update SD Forge Neo", CheckForUpdates)
    }
    A_TrayMenu.Add("Restart Forge Neo", RestartForge)
    A_TrayMenu.Add("Exit", ExitForge)
    A_TrayMenu.Default := "Show/Hide Console"
    A_TrayMenu.ClickCount := 1
}

; ============ Functions ============
LaunchForge() {
    global ForgePID, ForgeNeoDir, ForgeNeoBat, HideConsoleOnLaunch, SuppressCrashNotice
    fullPath := ForgeNeoDir "\" ForgeNeoBat
    if !FileExist(fullPath) {
        TrayTip("Could not find " fullPath ".`nUse Settings to fix the path.", "Forge Neo Tray", 2)
        ForgePID := 0
        return
    }
    cmd := 'cmd.exe /c title ForgeNeoConsole && cd /d "' ForgeNeoDir '" && "' ForgeNeoBat '"'
    winState := HideConsoleOnLaunch ? "Hide" : ""
    Run(cmd, ForgeNeoDir, winState, &ForgePID)
    SuppressCrashNotice := false
}

OpenBrowser(*) {
    Run(ForgeNeoURL)
}

OpenInstallFolder(*) {
    global ForgeNeoDir
    if !FileExist(ForgeNeoDir) {
        ShowCenteredNotice("Forge Neo Tray", "That folder couldn't be found. Use Settings to fix the path.")
        return
    }
    Run(ForgeNeoDir)
}

; drive letter or UNC = absolute, otherwise relative to Forge Neo's folder
IsAbsolutePath(p) {
    return RegExMatch(p, "^[A-Za-z]:[\\/]") || SubStr(p, 1, 2) = "\\"
}

; grabs one value out of config.json without a full JSON parser - not worth it for
; two keys
GetForgeConfigValue(key) {
    global ForgeNeoDir
    configPath := ForgeNeoDir "\config.json"
    if !FileExist(configPath)
        return ""
    try content := FileRead(configPath)
    catch {
        return ""
    }
    if !RegExMatch(content, '"' key '"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
        return ""
    val := StrReplace(m[1], '\\', '\')
    val := StrReplace(val, '\"', '"')
    return val
}

; pulls "owner/repo" out of the git remote URL rather than hardcoding it, so this
; keeps working if the remote ever changes. Handles both HTTPS and SSH remote formats.
GetGitHubRepoSlug(workDir) {
    url := RunGitCapture(workDir, "remote get-url origin")
    if RegExMatch(url, "github\.com[:/]([^/]+/[^/.]+)", &m)
        return m[1]
    return ""
}

; grabs the release notes text from GitHub's API - not stored in git itself.
; curl.exe + regex again, same as GetForgeConfigValue
FetchGitHubReleaseNotes(workDir, tag) {
    slug := GetGitHubRepoSlug(workDir)
    if slug = ""
        return ""
    url := "https://api.github.com/repos/" slug "/releases/tags/" tag
    tmp := A_Temp "\ForgeNeoTray_relnotes_" A_TickCount "_" Random(1000, 9999) ".json"
    try FileDelete(tmp)
    exitCode := RunWait('curl.exe -s -H "User-Agent: ForgeNeoTray" -o "' tmp '" "' url '"', , "Hide")
    content := FileExist(tmp) ? FileRead(tmp) : ""
    try FileDelete(tmp)
    if exitCode != 0 || content = ""
        return ""
    if !RegExMatch(content, '"body"\s*:\s*"((?:[^"\\]|\\.)*)"', &m)
        return ""
    body := StrReplace(m[1], "\r\n", "`n")
    body := StrReplace(body, "\n", "`n")
    body := StrReplace(body, "\t", "`t")
    body := StrReplace(body, '\"', '"')
    body := StrReplace(body, "\\", "\")
    return Trim(body)
}

; reads the real output dirs from config.json if set, otherwise the default guess
GetForgeOutputDir(kind) {
    global ForgeNeoDir
    key := (kind = "txt2img") ? "outdir_txt2img_samples" : "outdir_img2img_samples"
    custom := GetForgeConfigValue(key)
    if custom = ""
        return ForgeNeoDir "\output\" kind "-images"
    if IsAbsolutePath(custom)
        return custom
    return ForgeNeoDir "\" custom
}

; "Directory for saving images using the Save button" - defaults to output\images
GetForgeSaveDir() {
    global ForgeNeoDir
    custom := GetForgeConfigValue("outdir_save")
    if custom = ""
        return ForgeNeoDir "\output\images"
    if IsAbsolutePath(custom)
        return custom
    return ForgeNeoDir "\" custom
}

; "Output Directory" under Settings > Saving > Paths for saving - if set, this
; overrides the separate txt2img/img2img folders and sends everything to one place
GetForgeSharedOutputDir() {
    global ForgeNeoDir
    custom := GetForgeConfigValue("outdir_samples")
    if custom = ""
        return ""
    if IsAbsolutePath(custom)
        return custom
    return ForgeNeoDir "\" custom
}

OpenFolderPath(path) {
    if !FileExist(path) {
        SetTrayIcon()
        ShowCenteredNotice("Forge Neo Tray", "That folder couldn't be found:`n" WrapText(path, "\", 50) "`n`nThe tray menu refreshes every 60 seconds, so a just-deleted folder can briefly still appear. It's been refreshed now.")
        return
    }
    Run(path)
}

; AHK reuses the loop var across iterations, so a closure made directly in the loop
; would always point at the last folder. this factory fixes that.
MakeOpenFolderCallback(path) {
    return (*) => OpenFolderPath(path)
}

; YYYY-MM-DD subfolders, newest first
GetDateSubfolders(parentDir) {
    names := []
    if !FileExist(parentDir)
        return names
    Loop Files, parentDir "\*.*", "D" {
        if RegExMatch(A_LoopFileName, "^\d{4}-\d{2}-\d{2}$")
            names.Push(A_LoopFileName)
    }
    if names.Length = 0
        return names
    joined := ""
    for i, n in names
        joined .= (i = 1 ? "" : "`n") n
    return StrSplit(Sort(joined, "R"), "`n")
}

; becomes a submenu if there are date subfolders, otherwise just a plain item
AddFolderMenuItem(parentMenu, label, folderPath, includeOpenEntry := true) {
    dateFolders := GetDateSubfolders(folderPath)
    if dateFolders.Length = 0 {
        parentMenu.Add(label, MakeOpenFolderCallback(folderPath))
        return
    }
    subMenu := Menu()
    if includeOpenEntry {
        subMenu.Add("Open " label " Folder", MakeOpenFolderCallback(folderPath))
        subMenu.Add()
    }
    for d in dateFolders
        subMenu.Add(d, MakeOpenFolderCallback(folderPath "\" d))
    parentMenu.Add(label, subMenu)
}

; taskkill /T kills by PID tree, not window handle - WinClose doesn't work here since
; Windows Terminal (if it's your default) owns the actual window, not cmd.exe
KillForgeProcess() {
    global ForgePID
    if ForgePID && ProcessExist(ForgePID) {
        try RunWait('taskkill /F /T /PID ' ForgePID, , "Hide")
    }
    ForgePID := 0
}

RunGitCapture(workDir, gitArgs) {
    tmp := A_Temp "\ForgeNeoTray_git_" A_TickCount "_" Random(1000, 9999) ".txt"
    RunWait('cmd.exe /c cd /d "' workDir '" && git ' gitArgs ' > "' tmp '" 2>&1', , "Hide")
    result := FileExist(tmp) ? Trim(FileRead(tmp)) : ""
    try FileDelete(tmp)
    return result
}

DetectGitFailureReason(output) {
    if InStr(output, "Your local changes")
        return "You have local changes that would be overwritten."
    else if RegExMatch(output, "i)could not resolve host|unable to access|Could not read from remote")
        return "Couldn't reach GitHub. Check your internet connection."
    return "See details below for the full output."
}

; releaseTag: pass a real tag for release notes, omit/FETCH_HEAD to skip (HEAD mode,
; extensions - no GitHub release notes for those)
; focuses an already-open update window instead of letting a second one spawn -
; a new tray click can interrupt code paused in WinWaitClose, so without this
; you'd get duplicate windows
TryFocusExistingUpdateFlow() {
    global UpdateFlowGuiRef
    if IsObject(UpdateFlowGuiRef) {
        try {
            WinActivate("ahk_id " UpdateFlowGuiRef.Hwnd)
            return true
        } catch {
            UpdateFlowGuiRef := 0
        }
    }
    return false
}

; ShowBusyNotice doesn't self-close, caller destroys it - so this pairs with that
; to clear UpdateFlowGuiRef too
CloseBusyNotice(busyGui) {
    global UpdateFlowGuiRef
    busyGui.Destroy()
    UpdateFlowGuiRef := 0
}

ShowUpdateAvailableDialog(msg, releaseTag := "") {
    global ForgeNeoDir, UpdateFlowGuiRef
    result := {proceed: false}
    expanded := false
    NotesEdit := 0
    Dlg := Gui("-DPIScale", "Update Available")
    UpdateFlowGuiRef := Dlg
    Dlg.SetFont("s10")
    MsgText := Dlg.AddText("xm ym w400", msg)

    hasTag := releaseTag != "" && releaseTag != "FETCH_HEAD"
    if hasTag {
        ExpandBtn := Dlg.AddButton("xm y+15 w180", "Show Release Notes")
        ExpandBtn.GetPos(&ebx, &eby, &ebw, &ebh)
        ExpandBtn.OnEvent("Click", ToggleNotes)
    } else {
        MsgText.GetPos(&ebx, &eby, &ebw, &ebh)
    }

    CancelBtn := Dlg.AddButton("xm y" (eby + ebh + 15) " w110", "Cancel")
    UpdateBtn := Dlg.AddButton("xm+260 yp w140 Default", "Update Now")
    UpdateBtn.OnEvent("Click", (*) => (result.proceed := true, Dlg.Destroy()))
    CancelBtn.OnEvent("Click", (*) => Dlg.Destroy())
    Dlg.OnEvent("Close", (*) => Dlg.Destroy())

    ; same lazy-create + explicit-height-override pattern already proven in
    ; ShowUpdateResultNotice's ToggleExpand - fetches on first click only, not upfront.
    ToggleNotes(*) {
        expanded := !expanded
        if !IsObject(NotesEdit) {
            notesText := FetchGitHubReleaseNotes(ForgeNeoDir, releaseTag)
            if notesText = ""
                notesText := "(couldn't load release notes - check your internet connection)"
            NotesEdit := Dlg.AddEdit("xm y" (eby + ebh + 10) " w400 h150 -Theme ReadOnly VScroll Multi", notesText)
        }
        NotesEdit.Visible := expanded
        ExpandBtn.Text := expanded ? "Hide Release Notes" : "Show Release Notes"
        if expanded {
            NotesEdit.GetPos(&nx, &ny, &nw, &nh)
            newY := ny + nh + 15
        } else {
            newY := eby + ebh + 15
        }
        CancelBtn.Move(, newY)
        UpdateBtn.Move(, newY)
        CancelBtn.GetPos(&cx, &cy, &cw, &ch)
        Dlg.Show("h" (cy + ch + 20))
        CenterGuiOnMonitor(Dlg)
    }

    Dlg.Show()
    CenterGuiOnMonitor(Dlg)
    WinWaitClose("ahk_id " Dlg.Hwnd)
    UpdateFlowGuiRef := 0
    return result
}

; read-only check, doesn't touch anything
GitIsAncestor(workDir, ancestorRef, descendantRef) {
    exitCode := RunWait('cmd.exe /c cd /d "' workDir '" && git merge-base --is-ancestor ' ancestorRef ' ' descendantRef, , "Hide")
    return exitCode = 0
}

; strips any embedded `r/`n anywhere in the string, not just the ends - RunGitCapture
; already trims leading/trailing whitespace, but this is a harder guarantee for text
; that's about to go straight into a dialog message.
CleanGitValue(s) {
    return Trim(RegExReplace(s, "[`r`n]+", ""))
}

; returns the tag name if HEAD sits exactly on a numbered release tag, otherwise ""
GetExactTagAtHead(workDir) {
    tag := CleanGitValue(RunGitCapture(workDir, "describe --tags --exact-match HEAD"))
    return RegExMatch(tag, "^\d+(\.\d+)*$") ? tag : ""
}

; "git describe" gives the nearest ancestor tag plus how many commits past it, e.g.
; "2.27-15-gdac2375f" - parses that into "15 commits ahead of 2.27". Returns "" if no
; tag is reachable at all (very old commit, or a shallow clone missing tags).
DescribeCommitsAheadOfTag(workDir, ref) {
    desc := CleanGitValue(RunGitCapture(workDir, "describe --tags " ref))
    if !RegExMatch(desc, "^(\d+(?:\.\d+)*)-(\d+)-g[0-9a-fA-F]+$", &m)
        return ""
    plural := (m[2] = "1") ? "" : "s"
    return m[2] " commit" plural " ahead of " m[1]
}

; "Current release: 2.27 (hash)" if HEAD is exactly a tagged release. Otherwise "Current
; commit: hash" with "(N commits ahead of 2.27)" on its own line if we can tell how far
; past the last release you are, or just the bare hash as a last resort.
FormatCurrentLabel(workDir, hash) {
    hash := CleanGitValue(hash)
    tag := GetExactTagAtHead(workDir)
    if tag != ""
        return "Current release: " tag " (" hash ")"
    aheadDesc := DescribeCommitsAheadOfTag(workDir, "HEAD")
    if aheadDesc != ""
        return "Current commit: " hash "`n(" aheadDesc ")"
    return "Current commit: " hash
}

; expandable details box, since raw git output can run to hundreds of lines
ShowUpdateResultNotice(summary, fullOutput, offerRestart) {
    global UpdateFlowGuiRef
    expanded := false
    DetailsEdit := 0
    hasDetails := Trim(fullOutput) != ""
    NoticeGui := Gui("-DPIScale", "Update Result")
    UpdateFlowGuiRef := NoticeGui
    NoticeGui.SetFont("s10")
    SummaryText := NoticeGui.AddText("xm ym w360", summary)

    if hasDetails {
        ExpandBtn := NoticeGui.AddButton("xm y+15 w150", "Expand Details")
        ExpandBtn.GetPos(&ebx, &eby, &ebw, &ebh)
        ExpandBtn.OnEvent("Click", ToggleExpand)
    } else {
        SummaryText.GetPos(&ebx, &eby, &ebw, &ebh)
    }

    if offerRestart {
        RestartBtn := NoticeGui.AddButton("xm y" (eby + ebh + 15) " w120", "Restart now")
        RestartBtn.OnEvent("Click", (*) => (NoticeGui.Destroy(), RestartForge()))
        OkBtn := NoticeGui.AddButton("xm+260 yp w100 Default", "OK")
    } else {
        OkBtn := NoticeGui.AddButton("xm+260 y" (eby + ebh + 15) " w100 Default", "OK")
    }
    OkBtn.OnEvent("Click", (*) => NoticeGui.Destroy())
    NoticeGui.OnEvent("Close", (*) => NoticeGui.Destroy())

    ; GuiControl has no .Destroy() - toggle visible instead. window height gets
    ; overridden manually each time since AHK's auto-size counts hidden controls too
    ToggleExpand(*) {
        expanded := !expanded
        if !IsObject(DetailsEdit)
            DetailsEdit := NoticeGui.AddEdit("xm y" (eby + ebh + 10) " w360 h200 -Theme ReadOnly VScroll Multi", fullOutput)
        DetailsEdit.Visible := expanded
        ExpandBtn.Text := expanded ? "Collapse Details" : "Expand Details"
        if expanded {
            DetailsEdit.GetPos(&dx, &dy, &dw, &dh)
            newY := dy + dh + 15
        } else {
            newY := eby + ebh + 15
        }
        if offerRestart {
            RestartBtn.Move(, newY)
            OkBtn.Move(, newY)
        } else {
            OkBtn.Move(, newY)
        }
        OkBtn.GetPos(&okx, &oky, &okw, &okh)
        NoticeGui.Show("h" (oky + okh + 20))
        CenterGuiOnMonitor(NoticeGui)
    }

    NoticeGui.Show()
    CenterGuiOnMonitor(NoticeGui)
    WinWaitClose("ahk_id " NoticeGui.Hwnd)
    UpdateFlowGuiRef := 0
}

; shared by the tray click and the silent launch check so they can't drift apart.
; HEAD mode fetches by branch name and compares to FETCH_HEAD instead of trusting
; origin/<branch> locally, which goes stale if the remote's default branch got renamed
CheckUpdateStatus() {
    global ForgeNeoDir, UpdateMode
    result := {ok: false, available: false, message: "", fetchOutput: "", target: "", displayTarget: ""}

    if UpdateMode = "head" {
        symrefOutput := RunGitCapture(ForgeNeoDir, "ls-remote --symref origin HEAD")
        if !RegExMatch(symrefOutput, "refs/heads/(\S+)\s+HEAD", &m) {
            result.message := "Update failed: Couldn't determine the default branch from the remote."
            result.fetchOutput := symrefOutput
            return result
        }
        branchName := m[1]

        fetchOutFile := A_Temp "\ForgeNeoTray_gitfetch.txt"
        try FileDelete(fetchOutFile)
        fetchExit := RunWait('cmd.exe /c cd /d "' ForgeNeoDir '" && git fetch origin ' branchName ' > "' fetchOutFile '" 2>&1', , "Hide")
        fetchOutput := FileExist(fetchOutFile) ? FileRead(fetchOutFile) : ""
        try FileDelete(fetchOutFile)
        result.fetchOutput := fetchOutput
        if fetchExit != 0 {
            result.message := "Update failed: " DetectGitFailureReason(fetchOutput)
            return result
        }
        result.ok := true

        currentHash := CleanGitValue(RunGitCapture(ForgeNeoDir, "rev-parse --short HEAD"))
        targetHash := CleanGitValue(RunGitCapture(ForgeNeoDir, "rev-parse --short FETCH_HEAD"))
        if targetHash = "" {
            result.message := "Couldn't resolve the fetched commit."
            return result
        }
        if currentHash = targetHash {
            result.message := "Already running the latest commit on " branchName "."
            return result
        }
        if !GitIsAncestor(ForgeNeoDir, "HEAD", "FETCH_HEAD") {
            result.message := "Can't safely update from your current state — your local history has diverged from origin/" branchName "."
            return result
        }
        countOutput := RunGitCapture(ForgeNeoDir, "rev-list HEAD..FETCH_HEAD --count")
        behindCount := RegExMatch(countOutput, "(\d+)", &cm) ? Integer(cm[1]) : 0
        plural := behindCount = 1 ? "" : "s"
        headline := behindCount > 0 ? (behindCount " new commit" plural " available on " branchName ".") : ("New commits available on " branchName ".")
        result.available := true
        result.target := "FETCH_HEAD"
        result.displayTarget := targetHash
        result.message := headline "`n`n" FormatCurrentLabel(ForgeNeoDir, currentHash) "`nLatest: " targetHash
    } else {
        fetchOutFile := A_Temp "\ForgeNeoTray_gitfetch.txt"
        try FileDelete(fetchOutFile)
        fetchExit := RunWait('cmd.exe /c cd /d "' ForgeNeoDir '" && git fetch --tags > "' fetchOutFile '" 2>&1', , "Hide")
        fetchOutput := FileExist(fetchOutFile) ? FileRead(fetchOutFile) : ""
        try FileDelete(fetchOutFile)
        result.fetchOutput := fetchOutput
        if fetchExit != 0 {
            result.message := "Update failed: " DetectGitFailureReason(fetchOutput)
            return result
        }
        result.ok := true

        tagList := RunGitCapture(ForgeNeoDir, "tag --sort=-v:refname")
        latestTag := ""
        for t in StrSplit(tagList, "`n") {
            t := Trim(t)
            if RegExMatch(t, "^\d+(\.\d+)*$") {
                latestTag := t
                break
            }
        }
        if latestTag = "" {
            result.message := "No tagged releases were found in this repository."
            return result
        }
        currentHash := CleanGitValue(RunGitCapture(ForgeNeoDir, "rev-parse --short HEAD"))
        tagHash := CleanGitValue(RunGitCapture(ForgeNeoDir, "rev-parse --short " latestTag))

        if currentHash = tagHash {
            result.message := "Already running the latest release (" latestTag ")."
            return result
        }
        if !GitIsAncestor(ForgeNeoDir, "HEAD", latestTag) {
            if GitIsAncestor(ForgeNeoDir, latestTag, "HEAD")
                result.message := "You're already ahead of the latest tagged release (" latestTag ") — you're on newer commits from the neo branch."
            else
                result.message := "Can't safely update to release " latestTag " from your current state — your local history has diverged from it."
            return result
        }
        result.available := true
        result.target := latestTag
        result.displayTarget := latestTag
        result.message := "Release " latestTag " is available.`n`n" FormatCurrentLabel(ForgeNeoDir, currentHash) "`nTarget release: " latestTag " (" tagHash ")"
    }
    return result
}

; only reached after explicit confirmation, never from the silent check
ApplyUpdate(target, displayTarget) {
    global ForgeNeoDir
    outFile := A_Temp "\ForgeNeoTray_gitpull.txt"
    try FileDelete(outFile)
    exitCode := RunWait('cmd.exe /c cd /d "' ForgeNeoDir '" && git merge --ff-only "' target '" > "' outFile '" 2>&1', , "Hide")
    output := FileExist(outFile) ? FileRead(outFile) : "(no output captured)"
    try FileDelete(outFile)

    if exitCode != 0 {
        summaryText := "Update failed: " DetectGitFailureReason(output)
    } else {
        summaryText := "Successfully updated to " displayTarget "."
    }
    ShowUpdateResultNotice(summaryText, output, exitCode = 0)
}

CheckForUpdates(*) {
    global ForgeNeoDir

    if TryFocusExistingUpdateFlow()
        return
    if !FileExist(ForgeNeoDir "\.git") {
        ShowUpdateResultNotice("This doesn't look like a git installation (no .git folder found in your Forge Neo directory), so it can't be updated this way.", "", false)
        return
    }

    busy := ShowBusyNotice("Checking for updates...")
    status := CheckUpdateStatus()
    CloseBusyNotice(busy)
    if !status.ok || !status.available {
        ShowUpdateResultNotice(status.message, status.fetchOutput, false)
        return
    }

    choice := ShowUpdateAvailableDialog(status.message, status.target)
    if !choice.proceed
        return

    ApplyUpdate(status.target, status.displayTarget)
}

; ============ Extension updates ============
; extensions don't really do tagged releases like the core repo does, so these just
; always track HEAD regardless of the release/HEAD setting

GetGitExtensionFolders() {
    global ForgeNeoDir
    result := []
    extDir := ForgeNeoDir "\extensions"
    if !FileExist(extDir)
        return result
    Loop Files, extDir "\*", "D" {
        if FileExist(A_LoopFileFullPath "\.git")
            result.Push(A_LoopFileName)
    }
    return result
}

CheckExtensionUpdateStatus(extDir) {
    result := {ok: false, available: false, message: "", fetchOutput: "", target: "", displayTarget: ""}

    symrefOutput := RunGitCapture(extDir, "ls-remote --symref origin HEAD")
    if !RegExMatch(symrefOutput, "refs/heads/(\S+)\s+HEAD", &m) {
        result.message := "Update failed: Couldn't determine the default branch from the remote."
        result.fetchOutput := symrefOutput
        return result
    }
    branchName := m[1]

    ; fetch this branch by name directly - single-branch clones (common for
    ; extensions) can leave the local tracking ref stale otherwise
    fetchOutFile := A_Temp "\ForgeNeoTray_extfetch_" A_TickCount "_" Random(1000, 9999) ".txt"
    try FileDelete(fetchOutFile)
    fetchExit := RunWait('cmd.exe /c cd /d "' extDir '" && git fetch origin ' branchName ' > "' fetchOutFile '" 2>&1', , "Hide")
    fetchOutput := FileExist(fetchOutFile) ? FileRead(fetchOutFile) : ""
    try FileDelete(fetchOutFile)
    result.fetchOutput := fetchOutput

    if fetchExit != 0 {
        result.message := "Update failed: " DetectGitFailureReason(fetchOutput)
        return result
    }
    result.ok := true

    currentHash := CleanGitValue(RunGitCapture(extDir, "rev-parse --short HEAD"))
    targetHash := CleanGitValue(RunGitCapture(extDir, "rev-parse --short FETCH_HEAD"))

    if targetHash = "" {
        result.message := "Couldn't resolve the fetched commit for this extension."
        return result
    }
    if currentHash = targetHash {
        result.message := "Already up to date."
        return result
    }
    if !GitIsAncestor(extDir, "HEAD", "FETCH_HEAD") {
        result.message := "Local history has diverged — can't safely update."
        return result
    }
    result.available := true
    result.target := "FETCH_HEAD"
    result.displayTarget := targetHash
    result.message := "Update available (" targetHash ")."
    return result
}

ApplyExtensionUpdate(extDir, target, displayTarget) {
    outFile := A_Temp "\ForgeNeoTray_extpull_" A_TickCount "_" Random(1000, 9999) ".txt"
    try FileDelete(outFile)
    exitCode := RunWait('cmd.exe /c cd /d "' extDir '" && git merge --ff-only "' target '" > "' outFile '" 2>&1', , "Hide")
    output := FileExist(outFile) ? FileRead(outFile) : ""
    try FileDelete(outFile)
    if exitCode != 0
        return {summary: "Update failed: " DetectGitFailureReason(output), output: output, updated: false}
    return {summary: "Updated to " displayTarget ".", output: output, updated: true}
}

; same loop-var factory trick as MakeOpenFolderCallback above
MakeUpdateExtensionCallback(extName) {
    return (*) => UpdateSingleExtension(extName)
}

UpdateSingleExtension(extName) {
    global ForgeNeoDir
    if TryFocusExistingUpdateFlow()
        return
    extDir := ForgeNeoDir "\extensions\" extName
    busy := ShowBusyNotice("Checking " extName " for updates...")
    status := CheckExtensionUpdateStatus(extDir)
    CloseBusyNotice(busy)
    if !status.ok || !status.available {
        ShowUpdateResultNotice(extName ": " status.message, status.fetchOutput, false)
        return
    }
    choice := ShowUpdateAvailableDialog(extName "`n`n" status.message)
    if !choice.proceed
        return
    result := ApplyExtensionUpdate(extDir, status.target, status.displayTarget)
    ShowUpdateResultNotice(extName ": " result.summary, result.output, result.updated)
}

; only extensions with an actual update get a checkbox, the rest are just grey text
ShowExtensionUpdateChecklist(items) {
    global UpdateFlowGuiRef
    result := {proceed: false, selected: []}
    Dlg := Gui("-DPIScale", "Update Extensions")
    UpdateFlowGuiRef := Dlg
    Dlg.SetFont("s10")
    Dlg.AddText("xm ym w400", "Select which extensions to update:")
    y := 40
    rows := []
    for it in items {
        if it.status.ok && it.status.available {
            c := Dlg.AddCheckbox("xm y" y " w400 Checked", it.name " — update available (" it.status.displayTarget ")")
            rows.Push({ctrl: c, item: it})
        } else {
            statusText := it.status.ok ? "up to date" : "check failed"
            Dlg.AddText("xm y" y " w400 cGray", it.name " — " statusText)
            rows.Push({ctrl: 0, item: it})
        }
        y += 26
    }
    CancelBtn := Dlg.AddButton("xm y" (y + 15) " w110", "Cancel")
    UpdateBtn := Dlg.AddButton("xm+250 yp w150 Default", "Update Selected")
    UpdateBtn.OnEvent("Click", ConfirmClick)
    CancelBtn.OnEvent("Click", (*) => Dlg.Destroy())
    Dlg.OnEvent("Close", (*) => Dlg.Destroy())

    ConfirmClick(*) {
        result.proceed := true
        for row in rows {
            if IsObject(row.ctrl) && row.ctrl.Value
                result.selected.Push(row.item)
        }
        Dlg.Destroy()
    }

    Dlg.Show()
    CenterGuiOnMonitor(Dlg)
    WinWaitClose("ahk_id " Dlg.Hwnd)
    UpdateFlowGuiRef := 0
    return result
}

; caller has to Destroy() this manually when done. small Sleep so it actually paints
; before the blocking git calls start
ShowBusyNotice(text) {
    global UpdateFlowGuiRef
    BusyGui := Gui("-DPIScale", "Please Wait")
    UpdateFlowGuiRef := BusyGui
    BusyGui.SetFont("s10")
    BusyGui.AddText("xm ym w300", text)
    BusyGui.Show()
    CenterGuiOnMonitor(BusyGui)
    Sleep(50)
    return BusyGui
}

UpdateAllExtensions(*) {
    global ForgeNeoDir
    if TryFocusExistingUpdateFlow()
        return
    extFolders := GetGitExtensionFolders()
    if extFolders.Length = 0 {
        ShowUpdateResultNotice("No git-based extensions were found in your extensions folder.", "", false)
        return
    }

    busy := ShowBusyNotice("Checking for extension updates...")
    items := []
    for name in extFolders {
        dir := ForgeNeoDir "\extensions\" name
        items.Push({name: name, dir: dir, status: CheckExtensionUpdateStatus(dir)})
    }
    CloseBusyNotice(busy)

    anyAvailable := false
    anyFailed := false
    for it in items {
        if it.status.ok && it.status.available
            anyAvailable := true
        if !it.status.ok
            anyFailed := true
    }
    if !anyAvailable && !anyFailed {
        ShowUpdateResultNotice("All extensions are already up to date.", "", false)
        return
    }

    choice := ShowExtensionUpdateChecklist(items)
    if !choice.proceed || choice.selected.Length = 0
        return

    resultLines := []
    for sel in choice.selected {
        r := ApplyExtensionUpdate(sel.dir, sel.status.target, sel.status.displayTarget)
        resultLines.Push(sel.name ": " r.summary)
    }
    combined := ""
    for i, line in resultLines
        combined .= (i = 1 ? "" : "`n") line
    ShowUpdateResultNotice("Updated " choice.selected.Length " extension(s). Restart Forge Neo for the changes to take effect.", combined, true)
}

; background check, tray notification only - never a dialog, never auto-installs
CheckUpdatesSilently() {
    global ForgeNeoDir, PendingUpdateStatus
    if !FileExist(ForgeNeoDir "\.git")
        return
    status := CheckUpdateStatus()
    if status.ok && status.available {
        PendingUpdateStatus := status
        TrayTip("An update is available (" status.displayTarget "). Click this notification to update now.", "Forge Neo Tray", 1)
    }
}

; true if remote is a newer version than localVer, comparing segment by segment as
; numbers (not as plain strings, which would wrongly put "1.10" before "1.5")
IsNewerVersion(remote, localVer) {
    remoteParts := StrSplit(remote, ".")
    localParts := StrSplit(localVer, ".")
    loop Max(remoteParts.Length, localParts.Length) {
        r := (A_Index <= remoteParts.Length) ? Integer(remoteParts[A_Index]) : 0
        l := (A_Index <= localParts.Length) ? Integer(localParts[A_Index]) : 0
        if r > l
            return true
        if r < l
            return false
    }
    return false
}

; same curl + regex approach as FetchGitHubReleaseNotes, just against the "latest
; release" endpoint instead of a specific tag, and pulling tag_name instead of body
FetchForgeNeoTrayLatestVersion() {
    global ForgeNeoTrayGitHubRepo
    url := "https://api.github.com/repos/" ForgeNeoTrayGitHubRepo "/releases/latest"
    tmp := A_Temp "\ForgeNeoTray_selfupdate_" A_TickCount "_" Random(1000, 9999) ".json"
    try FileDelete(tmp)
    exitCode := RunWait('curl.exe -s -H "User-Agent: ForgeNeoTray" -o "' tmp '" "' url '"', , "Hide")
    content := FileExist(tmp) ? FileRead(tmp) : ""
    try FileDelete(tmp)
    if exitCode != 0 || content = ""
        return ""
    ; v? handles an optional leading "v" in the tag (e.g. v1.5), since GitHub tags
    ; commonly use that prefix even though the version itself is just "1.5"
    if !RegExMatch(content, '"tag_name"\s*:\s*"v?([\d.]+)"', &m)
        return ""
    return m[1]
}

; no git repo here, just a plain version string vs GitHub's latest tag. Click opens
; the Releases page - no self-replace, that needs a separate helper process
CheckForgeNeoTrayUpdateSilently() {
    global ForgeNeoTrayVersion, PendingSelfUpdateVersion
    latest := FetchForgeNeoTrayLatestVersion()
    if latest = ""
        return
    if IsNewerVersion(latest, ForgeNeoTrayVersion) {
        PendingSelfUpdateVersion := latest
        TrayTip("ForgeNeoTray " latest " is available. Click this notification to view it on GitHub.", "Forge Neo Tray", 1)
    }
}

RestartForge(*) {
    global SuppressCrashNotice
    SuppressCrashNotice := true
    KillForgeProcess()
    LaunchForge()
}

ExitForge(*) {
    global SuppressCrashNotice
    SuppressCrashNotice := true
    KillForgeProcess()
    ExitApp()
}

; strips quotes so it compares cleanly against A_ScriptFullPath either way
GetStartupRegistryPath() {
    global RunKeyName, RunKeyPath
    try {
        val := RegRead(RunKeyPath, RunKeyName)
        return Trim(val, '"')
    } catch {
        return ""
    }
}

SetStartupState(enable) {
    global RunKeyName, RunKeyPath
    if enable {
        try {
            ; quoted like Windows does it, otherwise a space in the path breaks things
            RegWrite('"' A_ScriptFullPath '"', "REG_SZ", RunKeyPath, RunKeyName)
        } catch {
            MsgBox("Couldn't update the Windows startup setting. This may be restricted by system policy.", "Forge Neo Tray", "Icon!")
        }
    } else {
        try RegDelete(RunKeyPath, RunKeyName)
    }
}

; asks before taking over someone else's startup entry
ShowRepointStartupDialog(oldPath) {
    result := {rewrite: false}
    Dlg := Gui("-DPIScale", "Start with Windows")
    Dlg.SetFont("s10")
    Dlg.AddText("xm ym w380", "Start with Windows is already enabled for a different ForgeNeoTray.exe:`n`n" oldPath "`n`nPoint Windows startup to this copy instead?")
    NoBtn := Dlg.AddButton("xm y+20 w110", "No")
    YesBtn := Dlg.AddButton("xm+250 yp w130 Default", "Use This Copy")
    YesBtn.OnEvent("Click", (*) => (result.rewrite := true, Dlg.Destroy()))
    NoBtn.OnEvent("Click", (*) => Dlg.Destroy())
    Dlg.OnEvent("Close", (*) => Dlg.Destroy())
    Dlg.Show()
    CenterGuiOnMonitor(Dlg)
    WinWaitClose("ahk_id " Dlg.Hwnd)
    return result
}

; ============ Window positioning ============
; wraps text at the given delimiter once a line gets too long. tooltips use " ",
; paths use "\" since they've got no spaces to break on
WrapText(text, delimiter, maxLen) {
    parts := StrSplit(text, delimiter)
    lines := []
    current := ""
    for p in parts {
        candidate := current = "" ? p : current delimiter p
        if (StrLen(candidate) > maxLen && current != "") {
            lines.Push(current)
            current := p
        } else {
            current := candidate
        }
    }
    if current != ""
        lines.Push(current)
    result := ""
    for i, l in lines
        result .= (i = 1 ? "" : "`n") l
    return result
}

GetMonitorAtMouse() {
    CoordMode("Mouse", "Screen")
    MouseGetPos(&mx, &my)
    count := MonitorGetCount()
    loop count {
        MonitorGet(A_Index, &L, &T, &R, &B)
        if (mx >= L && mx < R && my >= T && my < B)
            return A_Index
    }
    return MonitorGetPrimary()
}

CenterGuiOnMonitor(guiObj) {
    try {
        monIdx := GetMonitorAtMouse()
        MonitorGetWorkArea(monIdx, &L, &T, &R, &B)
        guiObj.GetPos(&gx, &gy, &gw, &gh)
        newX := L + ((R - L) - gw) // 2
        newY := T + ((B - T) - gh) // 2
        newX := Max(L, Min(newX, R - gw))
        newY := Max(T, Min(newY, B - gh))
        guiObj.Move(newX, newY)
    } catch {
        ; window may already be gone (e.g. closed the instant before this ran) -
        ; nothing to center in that case, safe to just skip silently
    }
}

; plain MsgBox has nothing to center against this early, so use our own dialog instead
ShowCenteredNotice(title, message, offerSettings := false, offerRestart := false) {
    NoticeGui := Gui("-DPIScale", title)
    NoticeGui.SetFont("s10")
    NoticeGui.AddText("xm ym w360", message)
    if offerSettings {
        SettingsBtn := NoticeGui.AddButton("xm y+20 w100", "Settings")
        SettingsBtn.OnEvent("Click", OpenSettingsFromNotice)
        OkBtn := NoticeGui.AddButton("x+160 yp w100 Default", "OK")
    } else if offerRestart {
        RestartBtn := NoticeGui.AddButton("xm y+20 w120", "Restart now")
        RestartBtn.OnEvent("Click", (*) => (NoticeGui.Destroy(), RestartForge()))
        OkBtn := NoticeGui.AddButton("xm+260 yp w100 Default", "OK")
    } else {
        OkBtn := NoticeGui.AddButton("xm+260 y+20 w100 Default", "OK")
    }
    OkBtn.OnEvent("Click", (*) => NoticeGui.Destroy())
    NoticeGui.OnEvent("Close", (*) => NoticeGui.Destroy())
    NoticeGui.Show()
    CenterGuiOnMonitor(NoticeGui)
    WinWaitClose("ahk_id " NoticeGui.Hwnd)

    OpenSettingsFromNotice(*) {
        global PendingSettingsAlwaysOnTop
        NoticeGui.Destroy()
        PendingSettingsAlwaysOnTop := true
        OpenSettingsWindow()
    }
}

; ============ Settings window ============
OpenSettingsWindow(*) {
    global ForgeNeoDir, ForgeNeoBat, ForgeNeoURL, SettingsPath, SettingsGuiRef, HideConsoleOnLaunch, StartupDelaySeconds, PendingSettingsAlwaysOnTop, UpdateMode, CheckUpdatesOnLaunch, EnableExtensionsUpdater, DoubleClickAction, DoubleClickIntervalMs, CheckSelfUpdatesOnLaunch

    if IsObject(SettingsGuiRef) {
        WinActivate("ahk_id " SettingsGuiRef.Hwnd)
        return
    }

    keepOnTop := PendingSettingsAlwaysOnTop
    PendingSettingsAlwaysOnTop := false

    SettingsGui := Gui("-DPIScale", "Settings (v" ForgeNeoTrayVersion ")")
    SettingsGuiRef := SettingsGui
    SettingsGui.SetFont("s10")
    HoverTips := Map()

    SettingsGui.AddText("xm ym", "Path to webui-user.bat:")
    BatEdit := SettingsGui.AddEdit("xm w470 vBatEdit -Theme", ForgeNeoDir "\" ForgeNeoBat)
    BrowseBtn := SettingsGui.AddButton("x+10 w95 yp-2", "Browse...")
    BrowseBtn.OnEvent("Click", BrowseAndRefreshArgs)
    HoverTips[BatEdit.Hwnd] := "Full path to your webui-user.bat file. Requires a restart to take effect."
    HoverTips[BrowseBtn.Hwnd] := "Browse for your webui-user.bat file. Requires a restart to take effect."

    SettingsGui.AddText("xm y+15", "Forge Neo URL:")
    UrlEdit := SettingsGui.AddEdit("xm w575 vUrlEdit -Theme", ForgeNeoURL)
    HoverTips[UrlEdit.Hwnd] := "Forge Neo's WebUI address. Only change this if you've customised the port. Requires a restart."

    StartupCheck := SettingsGui.AddCheckbox("xm y+15 vStartupCheck", "Start with Windows")
    StartupCheck.Value := (GetStartupRegistryPath() = A_ScriptFullPath)
    StartupCheck.OnEvent("Click", ClearStartupSuppress)
    HoverTips[StartupCheck.Hwnd] := "Launches ForgeNeoTray automatically at Windows startup. Takes effect next sign-in."

    HideConsoleCheck := SettingsGui.AddCheckbox("x+30 yp vHideConsoleCheck", "Hide console window on launch")
    HideConsoleCheck.Value := HideConsoleOnLaunch
    HoverTips[HideConsoleCheck.Hwnd] := "Hides the console window on launch. Requires a restart to take effect."

    SettingsGui.AddText("xm y+15", "Startup delay (seconds):")
    DelayEdit := SettingsGui.AddEdit("x+10 w60 vDelayEdit Number yp-2 -Theme", StartupDelaySeconds)
    HoverTips[DelayEdit.Hwnd] := "Delay before the first launch at Windows startup. Doesn't apply to Restart Forge Neo."

    SettingsGui.AddText("xm y+18", "Double-click tray icon action:")
    DoubleClickCombo := SettingsGui.AddDropDownList("x+10 w280 vDoubleClickCombo -Theme", ["Launch in browser", "Open most recent output folder", "Open saved image folder", "Open install folder", "Open models folder"])
    doubleClickIndex := 1
    for i, val in GetDoubleClickOptionValues() {
        if val = DoubleClickAction {
            doubleClickIndex := i
            break
        }
    }
    DoubleClickCombo.Value := doubleClickIndex
    HoverTips[DoubleClickCombo.Hwnd] := "What double-clicking the tray icon does. Single-click still shows/hides the console."

    SettingsGui.AddText("xm y+15", "Tray double-click speed (ms):")
    IntervalEdit := SettingsGui.AddEdit("x+10 w60 vIntervalEdit Number yp-2 -Theme", DoubleClickIntervalMs)
    HoverTips[IntervalEdit.Hwnd] := "Max time between clicks that still counts as a double-click. Default 200."

    CheckUpdatesCheck := SettingsGui.AddCheckbox("xm y+8 vCheckUpdatesCheck", "Check for SD Forge Neo updates on launch")
    CheckUpdatesCheck.Value := CheckUpdatesOnLaunch
    HoverTips[CheckUpdatesCheck.Hwnd] := "Checks for an SD Forge Neo update a few seconds after launch and notifies you if one's found. Never installs automatically. Needs a full restart of ForgeNeoTray to take effect."

    CheckSelfUpdatesCheck := SettingsGui.AddCheckbox("xm y+15 vCheckSelfUpdatesCheck", "Check for ForgeNeoTray updates on launch")
    CheckSelfUpdatesCheck.Value := CheckSelfUpdatesOnLaunch
    HoverTips[CheckSelfUpdatesCheck.Hwnd] := "Checks GitHub for a newer ForgeNeoTray release after launch. Clicking the notification opens the release page - nothing installs automatically."

    SettingsGui.AddText("xm y+15", "Update SD Forge Neo from:")
    UpdateModeDDL := SettingsGui.AddDropDownList("x+10 w330 vUpdateModeDDL -Theme", ["Latest stable release", "Latest commits — may include WIP/bugs"])
    UpdateModeDDL.Value := (UpdateMode = "head") ? 2 : 1
    HoverTips[UpdateModeDDL.Hwnd] := "Latest stable release checks tagged versions only. Latest commits tracks the branch directly, newer but may include unfinished work."

    ExtUpdaterCheck := SettingsGui.AddCheckbox("xm y+8 vExtUpdaterCheck", "Enable extensions updater in tray menu (untested)")
    ExtUpdaterCheck.Value := EnableExtensionsUpdater
    HoverTips[ExtUpdaterCheck.Hwnd] := "Adds an Extensions option under Check for Updates in the tray."

    OriginalArgsStr := ReadCommandLineArgs(ForgeNeoDir "\" ForgeNeoBat)
    ArgDefsList := GetArgDefs()
    ParsedArgs := ParseArgsIntoDefs(OriginalArgsStr, ArgDefsList)

    HeaderCtrl := SettingsGui.AddText("xm y+18", "Command-line Arguments:")
    HeaderCtrl.GetPos(&hx, &hy, &hw, &hh)
    gridX := hx
    gridY := hy + hh + 6
    rowH := 26
    colW := 300

    ArgCheckCtrls := []
    ArgValueCtrls := []
    MedVramChk := 0
    LowVramChk := 0
    ApiChk := 0
    CorsChk := 0
    CorsValEdit := 0
    totalRows := Ceil(ArgDefsList.Length / 2)
    for i, def in ArgDefsList {
        col := (i - 1) // totalRows
        row := Mod(i - 1, totalRows)
        cx := gridX + col * colW
        cy := gridY + row * rowH
        chkWidth := 220
        displayLabel := def[1]
        if def[1] = "--reserve-vram"
            chkWidth := 165
        else if def[1] = "--cors-allow-origins"
            chkWidth := 205
        else if (def[1] = "--cuda-malloc" || def[1] = "--cuda-stream") {
            chkWidth := 270
            displayLabel := def[1] " (Nvidia GPU)"
        }
        chk := SettingsGui.AddCheckbox("x" cx " y" cy " w" chkWidth, displayLabel)
        chk.Value := ParsedArgs.checked[i]
        ArgCheckCtrls.Push(chk)
        HoverTips[chk.Hwnd] := def[4] " Requires a restart to take effect."
        if def[1] = "--medvram"
            MedVramChk := chk
        else if def[1] = "--lowvram"
            LowVramChk := chk
        else if def[1] = "--api"
            ApiChk := chk
        else if def[1] = "--cors-allow-origins"
            CorsChk := chk
        if def[2] {
            valEdit := SettingsGui.AddEdit("x+0 yp-3 w70 -Theme", ParsedArgs.values[i])
            ArgValueCtrls.Push(valEdit)
            HoverTips[valEdit.Hwnd] := def[4] " Requires a restart to take effect."
            if def[1] = "--cors-allow-origins"
                CorsValEdit := valEdit
        } else {
            ArgValueCtrls.Push(0)
        }
    }

    LastChk := ArgCheckCtrls[ArgCheckCtrls.Length]
    LastChk.GetPos(&lx, &ly, &lw, &lh)

    ; medvram/lowvram are mutually exclusive - grey out the other, unless both are
    ; already ticked (edited by hand) in which case leave both alone so it's fixable
    if !(MedVramChk.Value && LowVramChk.Value) {
        LowVramChk.Enabled := !MedVramChk.Value
        MedVramChk.Enabled := !LowVramChk.Value
    }
    MedVramChk.OnEvent("Click", (*) => LowVramChk.Enabled := !MedVramChk.Value)
    LowVramChk.OnEvent("Click", (*) => MedVramChk.Enabled := !LowVramChk.Value)

    ; cors-allow-origins does nothing without --api, so grey it out and untick it too
    UpdateCorsEnabled(*) {
        if !ApiChk.Value
            CorsChk.Value := false
        CorsChk.Enabled := ApiChk.Value
        CorsValEdit.Enabled := ApiChk.Value
    }
    ApiChk.OnEvent("Click", UpdateCorsEnabled)
    UpdateCorsEnabled()

    SettingsGui.AddText("x" gridX " y" (ly + lh + 12), "Additional arguments:")
    LeftoverEdit := SettingsGui.AddEdit("x" gridX " y+5 w575 vLeftoverArgs -Theme", ParsedArgs.leftover)
    HoverTips[LeftoverEdit.Hwnd] := "Anything not covered by the checkboxes above, kept as-is. Requires a restart."

    ; re-reads the newly picked .bat and updates the whole grid to match it
    BrowseAndRefreshArgs(*) {
        selected := BrowseForBat(BatEdit)
        if !selected
            return

        OriginalArgsStr := ReadCommandLineArgs(selected)
        newParsed := ParseArgsIntoDefs(OriginalArgsStr, ArgDefsList)
        for i, def in ArgDefsList {
            ArgCheckCtrls[i].Value := newParsed.checked[i]
            if def[2]
                ArgValueCtrls[i].Value := newParsed.values[i]
        }
        LeftoverEdit.Value := newParsed.leftover

        if (MedVramChk.Value && LowVramChk.Value) {
            MedVramChk.Enabled := true
            LowVramChk.Enabled := true
        } else {
            LowVramChk.Enabled := !MedVramChk.Value
            MedVramChk.Enabled := !LowVramChk.Value
        }
        UpdateCorsEnabled()
    }

    CancelBtn := SettingsGui.AddButton("xm y+20 w110", "Cancel")
    SaveRestartBtn := SettingsGui.AddButton("xm+205 yp w160", "Save && Restart")
    SaveBtn := SettingsGui.AddButton("xm+445 yp w130 Default", "Save")

    CancelBtn.OnEvent("Click", (*) => CloseSettings())
    SaveRestartBtn.OnEvent("Click", (*) => SaveClicked(true))
    SaveBtn.OnEvent("Click", (*) => SaveClicked(false))
    SettingsGui.OnEvent("Close", (*) => CloseSettings())

    SetTimer(CheckHoverTip, 150)

    CheckHoverTip() {
        static lastHwnd := 0
        static hoverStart := 0
        static shown := false
        CoordMode("Mouse", "Screen")
        CoordMode("ToolTip", "Screen")
        MouseGetPos(&mx, &my, &winUnderMouse, &ctrlHwnd, 2)
        try {
            valid := (winUnderMouse = SettingsGui.Hwnd) && HoverTips.Has(ctrlHwnd)
        } catch {
            valid := false
        }

        if !valid {
            if shown
                ToolTip()
            lastHwnd := 0
            shown := false
            return
        }

        if (ctrlHwnd != lastHwnd) {
            ; switched controls - clear and restart the delay timer
            if shown
                ToolTip()
            lastHwnd := ctrlHwnd
            hoverStart := A_TickCount
            shown := false
            return
        }

        if (!shown && (A_TickCount - hoverStart) >= 600) {
            ToolTip(WrapText(HoverTips[ctrlHwnd], " ", 50), mx + 16, my + 16)
            shown := true
        }
    }

    CloseSettings() {
        global SettingsGuiRef
        SetTimer(CheckHoverTip, 0)
        ToolTip()
        SettingsGui.Destroy()
        SettingsGuiRef := 0
    }

    SaveClicked(restart) {
        global ForgeNeoDir, ForgeNeoBat, ForgeNeoURL, SettingsPath, HideConsoleOnLaunch, StartupDelaySeconds, UpdateMode, CheckUpdatesOnLaunch, EnableExtensionsUpdater, DoubleClickAction, DoubleClickIntervalMs, CheckSelfUpdatesOnLaunch
        saved := SettingsGui.Submit(false)
        fullBatPath := saved.BatEdit
        newUrl := saved.UrlEdit
        newHideConsole := saved.HideConsoleCheck
        newDelay := saved.DelayEdit != "" ? Integer(saved.DelayEdit) : 0
        newUpdateMode := (UpdateModeDDL.Value = 2) ? "head" : "release"
        newCheckUpdates := saved.CheckUpdatesCheck
        newCheckSelfUpdates := saved.CheckSelfUpdatesCheck
        newExtUpdater := saved.ExtUpdaterCheck
        dcOptions := GetDoubleClickOptionValues()
        comboVal := DoubleClickCombo.Value
        if comboVal < 1 || comboVal > dcOptions.Length
            comboVal := 1
        newDoubleClickAction := dcOptions[comboVal]
        newDoubleClickInterval := saved.IntervalEdit != "" ? Integer(saved.IntervalEdit) : 200

        if !FileExist(fullBatPath) {
            MsgBox("That .bat file couldn't be found. Please check the path and try again.", "Forge Neo Tray", "Icon!")
            return
        }

        oldFullPath := ForgeNeoDir "\" ForgeNeoBat
        oldUrl := ForgeNeoURL
        oldHideConsole := HideConsoleOnLaunch

        checkedVals := []
        valueVals := []
        for i, def in ArgDefsList {
            checkedVals.Push(ArgCheckCtrls[i].Value)
            valueVals.Push(def[2] ? ArgValueCtrls[i].Value : "")
        }
        newArgsStr := BuildArgsString(ArgDefsList, checkedVals, valueVals, saved.LeftoverArgs)
        argsWriteOk := WriteCommandLineArgs(fullBatPath, newArgsStr)
        argsChanged := (Trim(newArgsStr) != Trim(OriginalArgsStr))

        SplitPath(fullBatPath, &fileName, &dirPath)
        ForgeNeoDir := dirPath
        ForgeNeoBat := fileName
        ForgeNeoURL := newUrl
        HideConsoleOnLaunch := newHideConsole
        StartupDelaySeconds := newDelay
        UpdateMode := newUpdateMode
        CheckUpdatesOnLaunch := newCheckUpdates
        CheckSelfUpdatesOnLaunch := newCheckSelfUpdates
        EnableExtensionsUpdater := newExtUpdater
        DoubleClickAction := newDoubleClickAction
        DoubleClickIntervalMs := newDoubleClickInterval
        if !SuppressStartupWrite
            SetStartupState(saved.StartupCheck)

        IniWrite(ForgeNeoDir, SettingsPath, "Settings", "ForgeNeoDir")
        IniWrite(ForgeNeoBat, SettingsPath, "Settings", "ForgeNeoBat")
        IniWrite(ForgeNeoURL, SettingsPath, "Settings", "ForgeNeoURL")
        IniWrite(HideConsoleOnLaunch, SettingsPath, "Settings", "HideConsoleOnLaunch")
        IniWrite(StartupDelaySeconds, SettingsPath, "Settings", "StartupDelaySeconds")
        IniWrite(UpdateMode, SettingsPath, "Settings", "UpdateMode")
        IniWrite(CheckUpdatesOnLaunch, SettingsPath, "Settings", "CheckUpdatesOnLaunch")
        IniWrite(CheckSelfUpdatesOnLaunch, SettingsPath, "Settings", "CheckSelfUpdatesOnLaunch")
        IniWrite(EnableExtensionsUpdater, SettingsPath, "Settings", "EnableExtensionsUpdater")
        IniWrite(DoubleClickAction, SettingsPath, "Settings", "DoubleClickAction")
        IniWrite(DoubleClickIntervalMs, SettingsPath, "Settings", "DoubleClickIntervalMs")

        SetTrayIcon()
        CloseSettings()

        if !argsWriteOk
            ShowCenteredNotice("Forge Neo Tray", "Couldn't find a COMMANDLINE_ARGS line in webui-user.bat, so the argument checkboxes weren't saved. Everything else was saved normally.")


        if restart {
            RestartForge()
        } else if (fullBatPath != oldFullPath || newUrl != oldUrl || newHideConsole != oldHideConsole || argsChanged) {
            ShowCenteredNotice("Forge Neo Tray", "Settings saved. Use 'Restart Forge Neo' for the changes to take effect.", false, true)
        }
    }

    SettingsGui.Show()
    CenterGuiOnMonitor(SettingsGui)
    if keepOnTop
        WinSetAlwaysOnTop(1, "ahk_id " SettingsGui.Hwnd)

    ; first control auto-focuses on Show() and Windows selects all its text - move
    ; the caret to the end instead
    caretPos := StrLen(BatEdit.Value)
    SendMessage(0x00B1, caretPos, caretPos, BatEdit)
}

BrowseForBat(editCtrl) {
    selected := FileSelect(1, editCtrl.Value, "Select webui-user.bat", "Batch Files (*.bat)")
    if selected
        editCtrl.Value := selected
    return selected
}

; ============ webui-user.bat COMMANDLINE_ARGS editing ============
ReadCommandLineArgs(batPath) {
    try content := FileRead(batPath)
    catch {
        return ""
    }
    for line in StrSplit(content, "`n", "`r") {
        if RegExMatch(line, "i)^\s*set\s+COMMANDLINE_ARGS\s*=\s*(.*)$", &m)
            return Trim(m[1])
    }
    return ""
}

WriteCommandLineArgs(batPath, newArgs) {
    try content := FileRead(batPath)
    catch {
        return false
    }

    lines := StrSplit(content, "`n")
    found := false
    for i, line in lines {
        hasCR := SubStr(line, -1) = "`r"
        bareLine := hasCR ? SubStr(line, 1, StrLen(line) - 1) : line
        if RegExMatch(bareLine, "i)^\s*set\s+COMMANDLINE_ARGS\s*=.*$") {
            lines[i] := "set COMMANDLINE_ARGS=" newArgs (hasCR ? "`r" : "")
            found := true
            break
        }
    }

    if !found {
        if newArgs = ""
            return true
        newContent := "set COMMANDLINE_ARGS=" newArgs "`r`n" content
    } else {
        newContent := ""
        for i, line in lines
            newContent .= (i = 1 ? "" : "`n") line
    }

    try FileCopy(batPath, batPath ".bak", true)
    try {
        FileDelete(batPath)
        FileAppend(newContent, batPath)
        return true
    } catch {
        return false
    }
}

; Known COMMANDLINE_ARGS flags shown as checkboxes. Format: [flag, hasValue, defaultValue]
GetArgDefs() {
    return [
        ["--reserve-vram", true, "2", "Reserves N GB of VRAM as a safety margin, preventing Windows/other apps from causing out-of-memory errors."],
        ["--medvram", false, "", "Reduces VRAM use by splitting the model across GPU/CPU, at some cost to speed. For GPUs with limited VRAM."],
        ["--lowvram", false, "", "Aggressively reduces VRAM use for very limited GPUs, at a significant cost to speed."],
        ["--cuda-malloc", false, "", "Enables PyTorch's built-in CUDA memory allocator, which can reduce memory fragmentation and improve speed."],
        ["--cuda-stream", false, "", "Enables asynchronous CUDA operations to overlap computation and data transfer, often improving speed."],
        ["--pin-shared-memory", false, "", "Uses pinned (page-locked) memory for faster CPU-GPU data transfers."],
        ["--nunchaku", false, "", "Enables support for Nunchaku-quantised (INT4) models for faster inference with lower VRAM use."],
        ["--cors-allow-origins", true, "*", "Allows web pages from the specified origin(s) to access the API. Use * to allow any origin."],
        ["--api", false, "", "Enables the REST API, needed for external tools (browser extensions, scripts) to control Forge Neo."],
        ["--listen", false, "", "Makes the WebUI accessible from other devices on your network, not just this PC."],
        ["--xformers", false, "", "Enables the xFormers memory-efficient attention implementation, often reducing VRAM use and improving speed."],
        ["--autolaunch", false, "", "Automatically opens your default browser to the WebUI once it finishes starting."],
        ["--skip-torch-cuda-test", false, "", "Skips the startup check that verifies CUDA is working. Useful if the check itself is failing incorrectly."],
        ["--administrator", false, "", "Relaunches Forge Neo with administrator privileges. Sometimes needed for symlink-based model sharing."]
    ]
}

; unrecognized args get returned separately so nothing gets lost
ParseArgsIntoDefs(argsStr, defs) {
    remaining := " " argsStr " "
    checked := []
    values := []
    for def in defs {
        flag := def[1]
        if def[2] {
            q := Chr(34)
            if RegExMatch(remaining, "i)(^|\s)" flag "\s+(" q "[^" q "]*" q "|\S+)", &m) {
                values.Push(Trim(m[2], '"'))
                checked.Push(true)
                remaining := StrReplace(remaining, m[0], " ")
            } else {
                values.Push(def[3])
                checked.Push(false)
            }
        } else {
            values.Push("")
            if RegExMatch(remaining, "i)(^|\s)" flag "(\s|$)", &m) {
                checked.Push(true)
                remaining := StrReplace(remaining, m[0], " ")
            } else {
                checked.Push(false)
            }
        }
    }
    leftover := Trim(RegExReplace(remaining, "\s+", " "))
    return {checked: checked, values: values, leftover: leftover}
}

BuildArgsString(defs, checkedArr, valuesArr, leftover) {
    argsStr := ""
    for i, def in defs {
        if checkedArr[i] {
            if def[2] {
                val := valuesArr[i] != "" ? valuesArr[i] : def[3]
                argsStr .= (argsStr = "" ? "" : " ") def[1] " " val
            } else {
                argsStr .= (argsStr = "" ? "" : " ") def[1]
            }
        }
    }
    if Trim(leftover) != ""
        argsStr .= (argsStr = "" ? "" : " ") Trim(leftover)
    return argsStr
}

; ============ First-run setup ============
; only shown if there's no ini yet and the bat isn't sitting next to the exe
FirstRunSetup() {
    global SettingsPath

    SetupGui := Gui("-DPIScale", "Forge Neo Tray - First-Time Setup")
    SetupGui.SetFont("s10")
    SetupGui.AddText("xm ym w380", "webui-user.bat wasn't found next to this program. Locate it below to continue:")
    BatEdit := SetupGui.AddEdit("xm y+10 w275 vBatEdit -Theme", "")
    SetupGui.AddButton("x+10 w95 yp-2", "Browse...").OnEvent("Click", (*) => BrowseForBat(BatEdit))

    SetupGui.AddText("xm y+15", "Forge Neo URL:")
    SetupGui.AddEdit("xm w380 vUrlEdit -Theme", "http://127.0.0.1:7860")

    ExitBtn := SetupGui.AddButton("xm y+20 w100", "Exit")
    ContinueBtn := SetupGui.AddButton("xm+270 yp w110 Default", "Continue")

    ExitBtn.OnEvent("Click", (*) => ExitApp())
    ContinueBtn.OnEvent("Click", ContinueClicked)
    SetupGui.OnEvent("Close", (*) => ExitApp())

    ContinueClicked(*) {
        global SettingsPath, SettingsGuiRef
        saved := SetupGui.Submit(false)
        fullBatPath := saved.BatEdit
        newUrl := saved.UrlEdit

        if !FileExist(fullBatPath) {
            MsgBox("That .bat file couldn't be found. Please check the path and try again.", "Forge Neo Tray", "Icon!")
            return
        }

        SplitPath(fullBatPath, &fileName, &dirPath)
        IniWrite(dirPath, SettingsPath, "Settings", "ForgeNeoDir")
        IniWrite(fileName, SettingsPath, "Settings", "ForgeNeoBat")
        IniWrite(newUrl, SettingsPath, "Settings", "ForgeNeoURL")
        IniWrite(0, SettingsPath, "Settings", "HideConsoleOnLaunch")
        IniWrite(0, SettingsPath, "Settings", "StartupDelaySeconds")
        IniWrite("release", SettingsPath, "Settings", "UpdateMode")
        IniWrite(0, SettingsPath, "Settings", "CheckUpdatesOnLaunch")
        IniWrite(0, SettingsPath, "Settings", "EnableExtensionsUpdater")
        IniWrite("browser", SettingsPath, "Settings", "DoubleClickAction")
        IniWrite(200, SettingsPath, "Settings", "DoubleClickIntervalMs")
        IniWrite(1, SettingsPath, "Settings", "CheckSelfUpdatesOnLaunch")

        InitRuntimeGlobals()
        CheckStartupRegistryOnLaunch()
        SetupGui.Destroy()

        ShowCenteredNotice("Forge Neo Tray", "Setup complete — launching Forge Neo now.`n`nRight-click the tray icon anytime to open Settings, including if you ever move this program to a different folder later.", true)

        StartForgeAndTray()
    }

    SetupGui.Show()
    CenterGuiOnMonitor(SetupGui)
}

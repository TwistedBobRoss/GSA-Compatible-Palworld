using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;

internal static class PalConHost
{
    private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
    private static readonly IntPtr PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE = new IntPtr(0x00020016);
    private const uint INFINITE = 0xFFFFFFFF;

    private static IntPtr _pseudoConsole = IntPtr.Zero;
    private static IntPtr _processHandle = IntPtr.Zero;
    private static Process _managedProcess;
    private static IntPtr _inputWrite = IntPtr.Zero;
    private static int _shutdownStarted;
    private static string _restUrl;
    private static string _restUser;
    private static string _restPassword;
    private static int _shutdownWaitSeconds = 5;
    private static int _pollSeconds = 10;
    private static readonly ManualResetEvent _readerFinished = new ManualResetEvent(false);
    private static StreamWriter _logWriter;
    private static StreamWriter _chatWriter;
    private static StreamWriter _eventWriter;
    private static readonly object _playerLock = new object();
    private static readonly Dictionary<string, PlayerSnapshot> _knownPlayers =
        new Dictionary<string, PlayerSnapshot>(StringComparer.OrdinalIgnoreCase);
    private static readonly Regex _chatRegex = new Regex(
        @"^(?:\[[\d-]+ [\d:]+(?:Z)?\] \[CHAT\] )?<(?<name>.+?)>\s(?<message>.*)$",
        RegexOptions.Compiled);
    private static readonly Regex _joinRegex = new Regex(
        @"^(?:\[[\d-]+ [\d:]+(?:Z)?\] \[LOG\] )?(?<name>.+?) (?:(?<endpoint>.+?) )?(?:connected|joined) the server\. \(User id: (?<id>[^,\)]+)(?:, Player id: (?<playerId>[^\)]+))?\)$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex _loginRegex = new Regex(
        @"'(?:\s*)?(?<name>.+?)' \(UserId=(?<id>.+?)(?:,\s*IP=(?<endpoint>.+?))?\) has logged in\.$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex _leaveRegex = new Regex(
        @"^(?:\[[\d-]+ [\d:]+(?:Z)?\] \[LOG\] )?(?<name>.+?) left the server\. \(User id: (?<id>.+?)\)$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);
    private static readonly Regex _logoutRegex = new Regex(
        @"'(?:\s*)?(?<name>.+?)' \(UserId=(?<id>.+?)(?:,\s*IP=(?<endpoint>.+?))?\) has logged out\.$",
        RegexOptions.Compiled | RegexOptions.IgnoreCase);

    private enum CtrlType
    {
        CTRL_C_EVENT = 0,
        CTRL_BREAK_EVENT = 1,
        CTRL_CLOSE_EVENT = 2,
        CTRL_LOGOFF_EVENT = 5,
        CTRL_SHUTDOWN_EVENT = 6
    }

    private delegate bool ConsoleCtrlDelegate(CtrlType ctrlType);
    private static ConsoleCtrlDelegate _consoleHandler;

    [StructLayout(LayoutKind.Sequential)]
    private struct COORD
    {
        public short X;
        public short Y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct STARTUPINFO
    {
        public int cb;
        public IntPtr lpReserved;
        public IntPtr lpDesktop;
        public IntPtr lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct STARTUPINFOEX
    {
        public STARTUPINFO StartupInfo;
        public IntPtr lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_INFORMATION
    {
        public IntPtr hProcess;
        public IntPtr hThread;
        public uint dwProcessId;
        public uint dwThreadId;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CreatePipe(out IntPtr hReadPipe, out IntPtr hWritePipe, IntPtr lpPipeAttributes, uint nSize);

    [DllImport("kernel32.dll")]
    private static extern int CreatePseudoConsole(COORD size, IntPtr hInput, IntPtr hOutput, uint dwFlags, out IntPtr phPC);

    [DllImport("kernel32.dll")]
    private static extern void ClosePseudoConsole(IntPtr hPC);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool InitializeProcThreadAttributeList(
        IntPtr lpAttributeList,
        int dwAttributeCount,
        int dwFlags,
        ref IntPtr lpSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool UpdateProcThreadAttribute(
        IntPtr lpAttributeList,
        uint dwFlags,
        IntPtr attribute,
        IntPtr lpValue,
        IntPtr cbSize,
        IntPtr lpPreviousValue,
        IntPtr lpReturnSize);

    [DllImport("kernel32.dll")]
    private static extern void DeleteProcThreadAttributeList(IntPtr lpAttributeList);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(
        string lpApplicationName,
        string lpCommandLine,
        IntPtr lpProcessAttributes,
        IntPtr lpThreadAttributes,
        bool bInheritHandles,
        uint dwCreationFlags,
        IntPtr lpEnvironment,
        string lpCurrentDirectory,
        ref STARTUPINFOEX lpStartupInfo,
        out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool CloseHandle(IntPtr hObject);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(IntPtr hHandle, uint dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(IntPtr hProcess, out uint lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(ConsoleCtrlDelegate handlerRoutine, bool add);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool WriteFile(
        IntPtr hFile,
        byte[] lpBuffer,
        uint nNumberOfBytesToWrite,
        out uint lpNumberOfBytesWritten,
        IntPtr lpOverlapped);

    private sealed class Options
    {
        public string Exe;
        public string WorkingDirectory;
        public string LogPath;
        public string ChatLogPath;
        public string EventLogPath;
        public string RestUrl;
        public string RestUser = "admin";
        public string RestPassword = "";
        public int ShutdownWait = 5;
        public int PollSeconds = 10;
        public string CaptureMode = "conpty";
        public List<string> ChildArguments = new List<string>();
    }

    private sealed class PlayerSnapshot
    {
        public string UserId;
        public string PlayerId;
        public string Name;
        public string AccountName;
    }

    public static int Main(string[] args)
    {
        try
        {
            Console.OutputEncoding = new UTF8Encoding(false);
            var options = ParseOptions(args);
            _restUrl = options.RestUrl;
            _restUser = options.RestUser;
            _restPassword = options.RestPassword;
            _shutdownWaitSeconds = options.ShutdownWait;
            _pollSeconds = options.PollSeconds;

            _logWriter = OpenLog(options.LogPath);
            _chatWriter = OpenLog(options.ChatLogPath);
            _eventWriter = OpenLog(options.EventLogPath);

            _consoleHandler = HandleConsoleSignal;
            SetConsoleCtrlHandler(_consoleHandler, true);
            AppDomain.CurrentDomain.ProcessExit += delegate
            {
                if (IsChildRunning())
                {
                    BeginGracefulShutdown("process exit");
                }
            };

            WriteHostLine("[PalConHost] Starting Palworld wrapper.");
            WriteHostLine("[PalConHost] Executable: " + options.Exe);
            WriteHostLine("[PalConHost] Capture mode: " + options.CaptureMode);

            if (string.Equals(options.CaptureMode, "pipe", StringComparison.OrdinalIgnoreCase))
            {
                return RunRedirectedProcess(options);
            }

            return RunPseudoConsole(options);
        }
        catch (Exception ex)
        {
            WriteHostLine("[PalConHost] FATAL: " + ex);
            return 1;
        }
        finally
        {
            DisposeWriter(_logWriter);
            DisposeWriter(_chatWriter);
            DisposeWriter(_eventWriter);
        }
    }

    private static Options ParseOptions(string[] args)
    {
        var options = new Options();
        var childMode = false;

        for (var index = 0; index < args.Length; index++)
        {
            var value = args[index];
            if (childMode)
            {
                options.ChildArguments.Add(value);
                continue;
            }

            if (value == "--")
            {
                childMode = true;
                continue;
            }

            if (index + 1 >= args.Length)
            {
                throw new ArgumentException("Missing value for " + value);
            }

            var next = args[++index];
            switch (value)
            {
                case "--exe":
                    options.Exe = next;
                    break;
                case "--workdir":
                    options.WorkingDirectory = next;
                    break;
                case "--log":
                    options.LogPath = next;
                    break;
                case "--chat-log":
                    options.ChatLogPath = next;
                    break;
                case "--event-log":
                    options.EventLogPath = next;
                    break;
                case "--rest-url":
                    options.RestUrl = next.TrimEnd('/');
                    break;
                case "--rest-user":
                    options.RestUser = next;
                    break;
                case "--rest-password":
                    options.RestPassword = next;
                    break;
                case "--shutdown-wait":
                    options.ShutdownWait = ParseBoundedInt(next, 0, 120, "--shutdown-wait");
                    break;
                case "--poll-seconds":
                    options.PollSeconds = ParseBoundedInt(next, 2, 300, "--poll-seconds");
                    break;
                case "--capture-mode":
                    if (!string.Equals(next, "pipe", StringComparison.OrdinalIgnoreCase) &&
                        !string.Equals(next, "conpty", StringComparison.OrdinalIgnoreCase))
                    {
                        throw new ArgumentException("--capture-mode must be pipe or conpty.");
                    }
                    options.CaptureMode = next.ToLowerInvariant();
                    break;
                default:
                    throw new ArgumentException("Unknown option " + value);
            }
        }

        if (string.IsNullOrWhiteSpace(options.Exe))
        {
            throw new ArgumentException("--exe is required.");
        }

        if (!File.Exists(options.Exe))
        {
            throw new FileNotFoundException("Child executable was not found.", options.Exe);
        }

        if (string.IsNullOrWhiteSpace(options.WorkingDirectory))
        {
            options.WorkingDirectory = Path.GetDirectoryName(options.Exe);
        }

        return options;
    }

    private static int ParseBoundedInt(string value, int min, int max, string optionName)
    {
        int parsed;
        if (!int.TryParse(value, out parsed) || parsed < min || parsed > max)
        {
            throw new ArgumentException(optionName + " must be between " + min + " and " + max + ".");
        }

        return parsed;
    }

    private static int RunRedirectedProcess(Options options)
    {
        using (var process = new Process())
        {
            process.StartInfo.FileName = options.Exe;
            process.StartInfo.Arguments = BuildCommandLine(options.ChildArguments);
            process.StartInfo.WorkingDirectory = options.WorkingDirectory;
            process.StartInfo.UseShellExecute = false;
            process.StartInfo.CreateNoWindow = true;
            process.StartInfo.RedirectStandardInput = true;
            process.StartInfo.RedirectStandardOutput = true;
            process.StartInfo.RedirectStandardError = true;
            process.EnableRaisingEvents = true;
            process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
            {
                if (eventArgs.Data != null)
                {
                    ProcessLogLine(StripAnsi(eventArgs.Data));
                }
            };
            process.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs eventArgs)
            {
                if (eventArgs.Data != null)
                {
                    ProcessLogLine(StripAnsi(eventArgs.Data));
                }
            };

            if (!process.Start())
            {
                throw new InvalidOperationException("Failed to start the Palworld process.");
            }

            _managedProcess = process;
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            StartPollThreadIfConfigured();
            StartInputRelayThread(delegate(string line)
            {
                process.StandardInput.WriteLine(line);
                process.StandardInput.Flush();
            });

            process.WaitForExit();
            process.WaitForExit();
            var exitCode = process.ExitCode;
            _managedProcess = null;
            WriteHostLine("[PalConHost] Palworld exited with code " + exitCode + ".");
            return exitCode;
        }
    }

    private static int RunPseudoConsole(Options options)
    {
        IntPtr inputRead = IntPtr.Zero;
        IntPtr outputWrite = IntPtr.Zero;
        IntPtr outputRead = IntPtr.Zero;
        IntPtr attributeList = IntPtr.Zero;
        IntPtr attributeListSize = IntPtr.Zero;
        PROCESS_INFORMATION processInfo = new PROCESS_INFORMATION();

        try
        {
            if (!CreatePipe(out inputRead, out _inputWrite, IntPtr.Zero, 0))
            {
                ThrowWin32("CreatePipe(input)");
            }

            if (!CreatePipe(out outputRead, out outputWrite, IntPtr.Zero, 0))
            {
                ThrowWin32("CreatePipe(output)");
            }

            var size = new COORD { X = 180, Y = 60 };
            var hresult = CreatePseudoConsole(size, inputRead, outputWrite, 0, out _pseudoConsole);
            if (hresult != 0)
            {
                throw new Win32Exception(hresult, "CreatePseudoConsole failed with HRESULT 0x" + hresult.ToString("X8"));
            }

            CloseHandle(inputRead);
            inputRead = IntPtr.Zero;
            CloseHandle(outputWrite);
            outputWrite = IntPtr.Zero;

            var startupInfo = new STARTUPINFOEX();
            startupInfo.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));

            InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref attributeListSize);
            attributeList = Marshal.AllocHGlobal(attributeListSize);
            startupInfo.lpAttributeList = attributeList;

            if (!InitializeProcThreadAttributeList(attributeList, 1, 0, ref attributeListSize))
            {
                ThrowWin32("InitializeProcThreadAttributeList");
            }

            if (!UpdateProcThreadAttribute(
                attributeList,
                0,
                PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE,
                _pseudoConsole,
                new IntPtr(IntPtr.Size),
                IntPtr.Zero,
                IntPtr.Zero))
            {
                ThrowWin32("UpdateProcThreadAttribute");
            }

            var commandLine = QuoteArgument(options.Exe);
            foreach (var childArgument in options.ChildArguments)
            {
                commandLine += " " + QuoteArgument(childArgument);
            }

            if (!CreateProcessW(
                null,
                commandLine,
                IntPtr.Zero,
                IntPtr.Zero,
                false,
                EXTENDED_STARTUPINFO_PRESENT,
                IntPtr.Zero,
                options.WorkingDirectory,
                ref startupInfo,
                out processInfo))
            {
                ThrowWin32("CreateProcessW");
            }

            _processHandle = processInfo.hProcess;
            CloseHandle(processInfo.hThread);
            processInfo.hThread = IntPtr.Zero;

            var outputReadForThread = outputRead;
            outputRead = IntPtr.Zero;
            var readerThread = new Thread(delegate() { DrainOutput(outputReadForThread); });
            readerThread.IsBackground = true;
            readerThread.Name = "PalConHost-output";
            readerThread.Start();

            StartInputRelayThread(delegate(string line)
            {
                var bytes = Encoding.UTF8.GetBytes(line + "\r\n");
                uint written;
                if (_inputWrite == IntPtr.Zero ||
                    !WriteFile(_inputWrite, bytes, (uint)bytes.Length, out written, IntPtr.Zero))
                {
                    throw new IOException("Failed to write to pseudo console input.");
                }
            });
            StartPollThreadIfConfigured();

            WaitForSingleObject(_processHandle, INFINITE);
            uint exitCode;
            if (!GetExitCodeProcess(_processHandle, out exitCode))
            {
                exitCode = 1;
            }

            WriteHostLine("[PalConHost] Palworld exited with code " + exitCode + ".");
            ClosePseudoConsoleSafe();
            _readerFinished.WaitOne(TimeSpan.FromSeconds(5));
            return unchecked((int)exitCode);
        }
        finally
        {
            if (attributeList != IntPtr.Zero)
            {
                DeleteProcThreadAttributeList(attributeList);
                Marshal.FreeHGlobal(attributeList);
            }

            CloseHandleSafe(ref inputRead);
            CloseHandleSafe(ref outputWrite);
            CloseHandleSafe(ref outputRead);
            CloseHandleSafe(ref _inputWrite);
            CloseHandleSafe(ref _processHandle);
            ClosePseudoConsoleSafe();
        }
    }

    private static void StartPollThreadIfConfigured()
    {
        if (string.IsNullOrWhiteSpace(_restUrl) || string.IsNullOrWhiteSpace(_restPassword))
        {
            return;
        }

        var playerThread = new Thread(PollPlayers);
        playerThread.IsBackground = true;
        playerThread.Name = "PalConHost-player-poll";
        playerThread.Start();
    }

    private static void StartInputRelayThread(Action<string> writeAction)
    {
        var inputThread = new Thread(delegate()
        {
            try
            {
                string line;
                while ((line = Console.ReadLine()) != null && IsChildRunning())
                {
                    writeAction(line);
                }
            }
            catch
            {
                // Input is optional. GSA normally controls Palworld through REST or RCON.
            }
        });
        inputThread.IsBackground = true;
        inputThread.Name = "PalConHost-input";
        inputThread.Start();
    }

    private static void DrainOutput(IntPtr outputRead)
    {
        try
        {
            using (var handle = new Microsoft.Win32.SafeHandles.SafeFileHandle(outputRead, true))
            using (var stream = new FileStream(handle, FileAccess.Read))
            using (var reader = new StreamReader(stream, new UTF8Encoding(false, false), true, 4096))
            {
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    ProcessLogLine(StripAnsi(line));
                }
            }
        }
        catch (Exception ex)
        {
            WriteHostLine("[PalConHost] Output reader stopped: " + ex.Message);
        }
        finally
        {
            _readerFinished.Set();
        }
    }

    private static void ProcessLogLine(string line)
    {
        Console.Out.WriteLine(line);
        Console.Out.Flush();
        WriteToLog(_logWriter, line);

        var chat = _chatRegex.Match(line);
        if (chat.Success)
        {
            WriteToLog(
                _chatWriter,
                Timestamp() + " [CHAT] <" + chat.Groups["name"].Value + "> " + chat.Groups["message"].Value);
        }

        var join = _joinRegex.Match(line);
        if (!join.Success)
        {
            join = _loginRegex.Match(line);
        }

        if (join.Success)
        {
            RecordPlayerJoin(
                join.Groups["id"].Value,
                join.Groups["playerId"].Value,
                join.Groups["name"].Value,
                string.Empty,
                "console");
            return;
        }

        var leave = _leaveRegex.Match(line);
        if (!leave.Success)
        {
            leave = _logoutRegex.Match(line);
        }

        if (leave.Success)
        {
            RecordPlayerLeave(leave.Groups["id"].Value, leave.Groups["name"].Value, "console");
        }
    }

    private static void PollPlayers()
    {
        while (IsChildRunning() && Volatile.Read(ref _shutdownStarted) == 0)
        {
            try
            {
                var response = GetJson("/v1/api/players");
                if (!string.IsNullOrWhiteSpace(response))
                {
                    var snapshot = new Dictionary<string, PlayerSnapshot>(StringComparer.OrdinalIgnoreCase);
                    using (var document = JsonDocument.Parse(response))
                    {
                        JsonElement players;
                        if (document.RootElement.ValueKind == JsonValueKind.Object &&
                            document.RootElement.TryGetProperty("players", out players) &&
                            players.ValueKind == JsonValueKind.Array)
                        {
                            foreach (var player in players.EnumerateArray())
                            {
                                if (player.ValueKind != JsonValueKind.Object)
                                {
                                    continue;
                                }

                                var id = GetJsonString(player, "userId");
                                if (string.IsNullOrWhiteSpace(id))
                                {
                                    continue;
                                }

                                var name = GetJsonString(player, "name");
                                snapshot[id] = new PlayerSnapshot
                                {
                                    UserId = id,
                                    PlayerId = GetJsonString(player, "playerId"),
                                    Name = string.IsNullOrWhiteSpace(name) ? id : name,
                                    AccountName = GetJsonString(player, "accountName")
                                };
                            }
                        }
                    }

                    lock (_playerLock)
                    {
                        foreach (var pair in snapshot)
                        {
                            PlayerSnapshot known;
                            if (!_knownPlayers.TryGetValue(pair.Key, out known) ||
                                (!string.IsNullOrWhiteSpace(pair.Value.PlayerId) &&
                                 !string.Equals(known.PlayerId, pair.Value.PlayerId, StringComparison.OrdinalIgnoreCase)))
                            {
                                RecordPlayerJoinLocked(pair.Value, "rest");
                            }
                        }

                        var departed = new List<KeyValuePair<string, PlayerSnapshot>>();
                        foreach (var pair in _knownPlayers)
                        {
                            if (!snapshot.ContainsKey(pair.Key))
                            {
                                departed.Add(pair);
                            }
                        }

                        foreach (var pair in departed)
                        {
                            RecordPlayerLeaveLocked(pair.Key, pair.Value.Name, "rest");
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                WriteToLog(_eventWriter, Timestamp() + " [REST_POLL_ERROR] " + ex.Message);
            }

            Thread.Sleep(TimeSpan.FromSeconds(_pollSeconds));
        }
    }

    private static string GetJsonString(JsonElement element, string propertyName)
    {
        JsonElement value;
        if (!element.TryGetProperty(propertyName, out value))
        {
            return null;
        }

        switch (value.ValueKind)
        {
            case JsonValueKind.String:
                return value.GetString();
            case JsonValueKind.Number:
            case JsonValueKind.True:
            case JsonValueKind.False:
                return value.ToString();
            default:
                return null;
        }
    }

    private static bool IsChildRunning()
    {
        var managed = _managedProcess;
        if (managed != null)
        {
            try
            {
                return !managed.HasExited;
            }
            catch
            {
                return false;
            }
        }

        return _processHandle != IntPtr.Zero;
    }

    private static string GetJson(string path)
    {
        var request = (HttpWebRequest)WebRequest.Create(_restUrl + path);
        request.Method = "GET";
        request.Timeout = 5000;
        var credentials = Convert.ToBase64String(
            Encoding.UTF8.GetBytes((_restUser ?? "admin") + ":" + (_restPassword ?? string.Empty)));
        request.Headers[HttpRequestHeader.Authorization] = "Basic " + credentials;
        using (var response = (HttpWebResponse)request.GetResponse())
        using (var reader = new StreamReader(response.GetResponseStream(), Encoding.UTF8))
        {
            return reader.ReadToEnd();
        }
    }

    private static void RecordPlayerJoin(
        string id,
        string playerId,
        string name,
        string accountName,
        string source)
    {
        lock (_playerLock)
        {
            RecordPlayerJoinLocked(
                new PlayerSnapshot
                {
                    UserId = id,
                    PlayerId = playerId,
                    Name = name,
                    AccountName = accountName
                },
                source);
        }
    }

    private static void RecordPlayerJoinLocked(PlayerSnapshot player, string source)
    {
        if (player == null || string.IsNullOrWhiteSpace(player.UserId))
        {
            return;
        }

        if (string.IsNullOrWhiteSpace(player.Name))
        {
            player.Name = player.UserId;
        }

        _knownPlayers[player.UserId] = player;
        var identity = "User id: " + player.UserId;
        if (!string.IsNullOrWhiteSpace(player.PlayerId))
        {
            identity += ", Player id: " + player.PlayerId;
        }

        var line = Timestamp() + " [LOG] " + player.Name + " joined the server. (" + identity + ")";
        WriteToLog(_eventWriter, line);
        if (source == "rest")
        {
            Console.Out.WriteLine(line);
            Console.Out.Flush();
            WriteToLog(_logWriter, line);
        }
    }

    private static void RecordPlayerLeave(string id, string name, string source)
    {
        lock (_playerLock)
        {
            RecordPlayerLeaveLocked(id, name, source);
        }
    }

    private static void RecordPlayerLeaveLocked(string id, string name, string source)
    {
        if (string.IsNullOrWhiteSpace(id))
        {
            return;
        }

        PlayerSnapshot known;
        if (_knownPlayers.TryGetValue(id, out known) && string.IsNullOrWhiteSpace(name))
        {
            name = known.Name;
        }

        if (string.IsNullOrWhiteSpace(name))
        {
            name = id;
        }

        _knownPlayers.Remove(id);
        var line = Timestamp() + " [LOG] " + name + " left the server. (User id: " + id + ")";
        WriteToLog(_eventWriter, line);
        if (source == "rest")
        {
            Console.Out.WriteLine(line);
            Console.Out.Flush();
            WriteToLog(_logWriter, line);
        }
    }

    private static bool HandleConsoleSignal(CtrlType ctrlType)
    {
        BeginGracefulShutdown(ctrlType.ToString());
        return true;
    }

    private static void BeginGracefulShutdown(string reason)
    {
        if (Interlocked.Exchange(ref _shutdownStarted, 1) != 0)
        {
            return;
        }

        WriteHostLine("[PalConHost] Shutdown requested: " + reason + ".");

        if (string.IsNullOrWhiteSpace(_restUrl) || string.IsNullOrWhiteSpace(_restPassword))
        {
            return;
        }

        TryPost("/v1/api/save", "{}");
        TryPost(
            "/v1/api/shutdown",
            "{\"waittime\":" + _shutdownWaitSeconds + ",\"message\":\"Server is shutting down\"}");

        if (_processHandle != IntPtr.Zero)
        {
            WaitForSingleObject(_processHandle, (uint)((_shutdownWaitSeconds + 10) * 1000));
        }
        else if (_managedProcess != null)
        {
            try
            {
                _managedProcess.WaitForExit((_shutdownWaitSeconds + 10) * 1000);
            }
            catch
            {
                // The process may already have exited.
            }
        }
    }

    private static void TryPost(string path, string json)
    {
        try
        {
            var request = (HttpWebRequest)WebRequest.Create(_restUrl + path);
            request.Method = "POST";
            request.ContentType = "application/json";
            request.Timeout = 5000;
            var credentials = Convert.ToBase64String(
                Encoding.UTF8.GetBytes((_restUser ?? "admin") + ":" + (_restPassword ?? string.Empty)));
            request.Headers[HttpRequestHeader.Authorization] = "Basic " + credentials;
            var bytes = Encoding.UTF8.GetBytes(json);
            request.ContentLength = bytes.Length;
            using (var requestStream = request.GetRequestStream())
            {
                requestStream.Write(bytes, 0, bytes.Length);
            }

            using (var response = (HttpWebResponse)request.GetResponse())
            {
                WriteHostLine("[PalConHost] REST " + path + " returned HTTP " + (int)response.StatusCode + ".");
            }
        }
        catch (Exception ex)
        {
            WriteHostLine("[PalConHost] REST " + path + " failed: " + ex.Message);
        }
    }

    private static string BuildCommandLine(List<string> arguments)
    {
        var builder = new StringBuilder();
        foreach (var argument in arguments)
        {
            if (builder.Length > 0)
            {
                builder.Append(' ');
            }

            builder.Append(QuoteArgument(argument));
        }

        return builder.ToString();
    }

    private static string StripAnsi(string value)
    {
        value = Regex.Replace(value, "\x1B\\][^\x07]*(?:\x07|\x1B\\\\)", string.Empty);
        return Regex.Replace(value, "\x1B(?:[@-Z\\\\-_]|\\[[0-?]*[ -/]*[@-~])", string.Empty);
    }

    private static StreamWriter OpenLog(string path)
    {
        if (string.IsNullOrWhiteSpace(path))
        {
            return null;
        }

        var directory = Path.GetDirectoryName(path);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        var writer = new StreamWriter(
            new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite),
            new UTF8Encoding(false));
        writer.AutoFlush = true;
        return writer;
    }

    private static void DisposeWriter(StreamWriter writer)
    {
        if (writer != null)
        {
            writer.Dispose();
        }
    }

    private static void WriteToLog(StreamWriter writer, string line)
    {
        if (writer == null)
        {
            return;
        }

        lock (writer)
        {
            writer.WriteLine(line);
            writer.Flush();
        }
    }

    private static string Timestamp()
    {
        return DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss") + "Z";
    }

    private static string QuoteArgument(string value)
    {
        if (value == null)
        {
            return "\"\"";
        }

        if (value.Length > 0 && !Regex.IsMatch(value, "[\\s\"]"))
        {
            return value;
        }

        var result = new StringBuilder();
        result.Append('"');
        var backslashes = 0;
        foreach (var character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }

            if (character == '"')
            {
                result.Append('\\', backslashes * 2 + 1);
                result.Append('"');
                backslashes = 0;
                continue;
            }

            result.Append('\\', backslashes);
            backslashes = 0;
            result.Append(character);
        }

        result.Append('\\', backslashes * 2);
        result.Append('"');
        return result.ToString();
    }

    private static void WriteHostLine(string value)
    {
        try
        {
            var line = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss") + "Z " + value;
            Console.Out.WriteLine(line);
            Console.Out.Flush();
            WriteToLog(_logWriter, line);
        }
        catch
        {
            // Avoid throwing from shutdown or error reporting.
        }
    }

    private static void ThrowWin32(string operation)
    {
        throw new Win32Exception(Marshal.GetLastWin32Error(), operation + " failed");
    }

    private static void CloseHandleSafe(ref IntPtr handle)
    {
        if (handle != IntPtr.Zero && handle.ToInt64() != -1)
        {
            CloseHandle(handle);
            handle = IntPtr.Zero;
        }
    }

    private static void ClosePseudoConsoleSafe()
    {
        var handle = Interlocked.Exchange(ref _pseudoConsole, IntPtr.Zero);
        if (handle != IntPtr.Zero)
        {
            ClosePseudoConsole(handle);
        }
    }
}

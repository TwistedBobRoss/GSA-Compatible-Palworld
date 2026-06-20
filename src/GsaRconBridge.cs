using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Web.Script.Serialization;

internal static class GsaRconBridge
{
    private const int ServerDataResponseValue = 0;
    private const int ServerDataExecCommand = 2;
    private const int ServerDataAuthResponse = 2;
    private const int ServerDataAuth = 3;
    private const int MaxPacketSize = 4096;
    private const int MaxBodyBytes = MaxPacketSize - 10;

    private static readonly object LogLock = new object();
    private static readonly object DeliveryLock = new object();
    private static readonly JavaScriptSerializer Json = new JavaScriptSerializer();
    private static readonly Regex SafeId = new Regex(
        @"^[A-Za-z0-9_.:@\-]{1,256}$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);
    private static readonly Regex SafeItem = new Regex(
        @"^[A-Za-z0-9_.:\-]{1,256}$",
        RegexOptions.Compiled | RegexOptions.CultureInvariant);

    private static string _listenAddress;
    private static int _listenPort;
    private static string _password;
    private static string _nativeHost;
    private static int _nativePort;
    private static bool _proxyNative;
    private static bool _sendEmptyAuthResponse;
    private static string _palRestUrl;
    private static string _palRestUser;
    private static string _palRestPassword;
    private static string _palDefenderUrl;
    private static string _palDefenderTokenFile;
    private static string _palDefenderToken;
    private static string _ledgerDirectory;
    private static string _logPath;
    private static StreamWriter _logWriter;
    private static TcpListener _listener;
    private static volatile bool _stopping;

    private sealed class RconPacket
    {
        public int RequestId;
        public int Type;
        public string Body;
    }

    private sealed class DeliveryRecord
    {
        public string DeliveryId;
        public string PlayerId;
        public string ItemId;
        public int Count;
        public string Status;
        public string Result;
        public string UpdatedUtc;
    }

    private sealed class HttpResult
    {
        public bool ReachedServer;
        public int StatusCode;
        public string Body;
        public string Error;
    }

    public static int Main(string[] args)
    {
        try
        {
            LoadConfiguration();
            Directory.CreateDirectory(_ledgerDirectory);
            OpenLog();

            Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs eventArgs)
            {
                eventArgs.Cancel = true;
                Stop();
            };
            AppDomain.CurrentDomain.ProcessExit += delegate { Stop(); };

            IPAddress address;
            if (!IPAddress.TryParse(_listenAddress, out address))
            {
                address = Dns.GetHostAddresses(_listenAddress)[0];
            }

            _listener = new TcpListener(address, _listenPort);
            _listener.Start();
            Log("INFO", "Source RCON gateway listening on " + _listenAddress + ":" + _listenPort + ".");
            Log("INFO", "Native RCON compatibility proxy: " + (_proxyNative ? _nativeHost + ":" + _nativePort : "disabled") + ".");

            while (!_stopping)
            {
                TcpClient client;
                try
                {
                    client = _listener.AcceptTcpClient();
                }
                catch (SocketException)
                {
                    if (_stopping)
                    {
                        break;
                    }
                    throw;
                }

                ThreadPool.QueueUserWorkItem(HandleClient, client);
            }

            return 0;
        }
        catch (Exception ex)
        {
            Log("FATAL", ex.ToString());
            return 1;
        }
        finally
        {
            Stop();
            lock (LogLock)
            {
                if (_logWriter != null)
                {
                    _logWriter.Dispose();
                    _logWriter = null;
                }
            }
        }
    }

    private static void LoadConfiguration()
    {
        _listenAddress = Env("PAL_BRIDGE_LISTEN_ADDRESS", "0.0.0.0");
        _listenPort = IntEnv("PAL_RCON_PORT", 25575, 1, 65535);
        _password = Env("PAL_ADMIN_PASSWORD", "");
        _nativeHost = Env("PAL_NATIVE_RCON_HOST", "127.0.0.1");
        _nativePort = IntEnv("PAL_NATIVE_RCON_PORT", 25576, 1, 65535);
        _proxyNative = BoolEnv("PAL_BRIDGE_PROXY_NATIVE", true) && _nativePort != _listenPort;
        _sendEmptyAuthResponse = BoolEnv("PAL_BRIDGE_AUTH_EMPTY_RESPONSE", false);
        _palRestUrl = Env("PAL_REST_URL", "http://127.0.0.1:8212").TrimEnd('/');
        _palRestUser = Env("PAL_REST_USER", "admin");
        _palRestPassword = Env("PAL_ADMIN_PASSWORD", "");
        _palDefenderUrl = Env("PALDEFENDER_REST_URL", "http://127.0.0.1:17993").TrimEnd('/');
        _palDefenderTokenFile = Env(
            "PALDEFENDER_TOKEN_FILE",
            @"C:\serverfiles\Pal\Binaries\Win64\PalDefender\RESTAPI\Tokens\GSA.json");
        _palDefenderToken = Env("PALDEFENDER_TOKEN", "");
        _ledgerDirectory = Env("PAL_BRIDGE_LEDGER", @"C:\serverfiles\PalBridge\ledger");
        _logPath = Env("PAL_BRIDGE_LOG", @"C:\serverfiles\Logs\PalBridge.log");

        if (string.IsNullOrWhiteSpace(_password))
        {
            throw new InvalidOperationException("PAL_ADMIN_PASSWORD must not be empty when the GSA RCON gateway is enabled.");
        }
    }

    private static void OpenLog()
    {
        var directory = Path.GetDirectoryName(_logPath);
        if (!string.IsNullOrWhiteSpace(directory))
        {
            Directory.CreateDirectory(directory);
        }

        _logWriter = new StreamWriter(
            new FileStream(_logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite),
            new UTF8Encoding(false));
        _logWriter.AutoFlush = true;
    }

    private static void Stop()
    {
        if (_stopping)
        {
            return;
        }

        _stopping = true;
        try
        {
            if (_listener != null)
            {
                _listener.Stop();
            }
        }
        catch
        {
        }
    }

    private static void HandleClient(object state)
    {
        var client = (TcpClient)state;
        var endpoint = Convert.ToString(client.Client.RemoteEndPoint, CultureInfo.InvariantCulture);
        client.NoDelay = true;
        client.ReceiveTimeout = 30000;
        client.SendTimeout = 30000;

        using (client)
        using (var stream = client.GetStream())
        {
            var authenticated = false;
            try
            {
                while (!_stopping)
                {
                    var packet = ReadPacket(stream);
                    if (packet == null)
                    {
                        return;
                    }

                    if (!authenticated)
                    {
                        if (packet.Type != ServerDataAuth)
                        {
                            Log("WARN", "Rejected unauthenticated packet from " + endpoint + ".");
                            return;
                        }

                        if (!ConstantTimeEquals(packet.Body, _password))
                        {
                            Thread.Sleep(500);
                            WritePacket(stream, -1, ServerDataAuthResponse, "");
                            Log("WARN", "RCON authentication failed from " + endpoint + ".");
                            return;
                        }

                        if (_sendEmptyAuthResponse)
                        {
                            WritePacket(stream, packet.RequestId, ServerDataResponseValue, "");
                        }
                        WritePacket(stream, packet.RequestId, ServerDataAuthResponse, "");
                        authenticated = true;
                        Log("INFO", "RCON client authenticated from " + endpoint + ".");
                        continue;
                    }

                    if (packet.Type != ServerDataExecCommand && packet.Type != ServerDataResponseValue)
                    {
                        WriteResponse(stream, packet.RequestId, "ERROR code=unsupported_packet_type");
                        continue;
                    }

                    if (string.IsNullOrEmpty(packet.Body))
                    {
                        WritePacket(stream, packet.RequestId, ServerDataResponseValue, "");
                        continue;
                    }

                    var response = ExecuteCommand(packet.Body);
                    WriteResponse(stream, packet.RequestId, response);
                }
            }
            catch (IOException)
            {
            }
            catch (SocketException)
            {
            }
            catch (Exception ex)
            {
                Log("ERROR", "RCON client " + endpoint + " failed: " + ex.Message);
            }
        }
    }

    private static string ExecuteCommand(string command)
    {
        var clean = command.Trim();
        Log("COMMAND", SanitizeForLog(clean));

        if (clean.Equals("palbridge ping", StringComparison.OrdinalIgnoreCase) ||
            clean.Equals("ping", StringComparison.OrdinalIgnoreCase))
        {
            return "OK status=ready protocol=source-rcon";
        }

        if (clean.Equals("palbridge version", StringComparison.OrdinalIgnoreCase))
        {
            return "OK version=0.1.0";
        }

        if (clean.StartsWith("palbridge give ", StringComparison.OrdinalIgnoreCase))
        {
            return ExecuteGive(clean);
        }

        if (clean.Equals("Save", StringComparison.OrdinalIgnoreCase))
        {
            return PalRestCommand("/v1/api/save", new Dictionary<string, object>());
        }

        if (clean.StartsWith("Broadcast ", StringComparison.OrdinalIgnoreCase))
        {
            var message = clean.Substring("Broadcast ".Length).Trim();
            return PalRestCommand(
                "/v1/api/announce",
                new Dictionary<string, object> { { "message", message } });
        }

        if (clean.StartsWith("Shutdown ", StringComparison.OrdinalIgnoreCase))
        {
            return ExecuteShutdown(clean.Substring("Shutdown ".Length));
        }

        if (clean.Equals("Info", StringComparison.OrdinalIgnoreCase))
        {
            return PalRestGet("/v1/api/info");
        }

        if (clean.Equals("ShowPlayers", StringComparison.OrdinalIgnoreCase))
        {
            return PalRestGet("/v1/api/players");
        }

        if (_proxyNative)
        {
            return ExecuteNativeRcon(clean);
        }

        return "ERROR code=command_not_allowed message=Command is not allowlisted";
    }

    private static string ExecuteGive(string command)
    {
        Dictionary<string, string> arguments;
        try
        {
            arguments = ParseNamedArguments(command.Substring("palbridge give".Length));
        }
        catch (Exception ex)
        {
            return "ERROR code=invalid_arguments message=" + OneLine(ex.Message);
        }

        string deliveryId;
        string playerId;
        string itemId;
        string countText;
        if (!arguments.TryGetValue("delivery", out deliveryId) ||
            !arguments.TryGetValue("player", out playerId) ||
            !arguments.TryGetValue("item", out itemId))
        {
            return "ERROR code=missing_argument message=delivery, player, and item are required";
        }

        if (!arguments.TryGetValue("count", out countText))
        {
            countText = "1";
        }

        int count;
        if (!SafeId.IsMatch(deliveryId) ||
            !SafeId.IsMatch(playerId) ||
            !SafeItem.IsMatch(itemId) ||
            !int.TryParse(countText, NumberStyles.None, CultureInfo.InvariantCulture, out count) ||
            count < 1 ||
            count > 1000000)
        {
            return "ERROR delivery=" + OneLine(deliveryId) + " code=invalid_argument message=Invalid delivery, player, item, or count";
        }

        lock (DeliveryLock)
        {
            var path = GetDeliveryPath(deliveryId);
            var existing = ReadDelivery(path);
            if (existing != null)
            {
                if (string.Equals(existing.Status, "delivered", StringComparison.OrdinalIgnoreCase))
                {
                    return "OK delivery=" + deliveryId + " status=already_delivered";
                }

                if (string.Equals(existing.Status, "pending", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(existing.Status, "uncertain", StringComparison.OrdinalIgnoreCase))
                {
                    return "ERROR delivery=" + deliveryId + " code=delivery_uncertain message=Manual reconciliation required before retry";
                }
            }

            var record = new DeliveryRecord
            {
                DeliveryId = deliveryId,
                PlayerId = playerId,
                ItemId = itemId,
                Count = count,
                Status = "pending",
                Result = "",
                UpdatedUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture)
            };
            WriteDelivery(path, record);

            var payload = new Dictionary<string, object>
            {
                { "UserID", playerId },
                {
                    "Items",
                    new object[]
                    {
                        new Dictionary<string, object>
                        {
                            { "ItemID", itemId },
                            { "Count", count }
                        }
                    }
                }
            };

            var token = LoadPalDefenderToken();
            if (string.IsNullOrWhiteSpace(token))
            {
                record.Status = "failed";
                record.Result = "PalDefender token is unavailable";
                record.UpdatedUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
                WriteDelivery(path, record);
                return "ERROR delivery=" + deliveryId + " code=backend_auth_unavailable message=PalDefender token is unavailable";
            }

            var result = SendHttp(
                "POST",
                _palDefenderUrl + "/v1/pdapi/give",
                Json.Serialize(payload),
                "Bearer " + token);

            if (result.ReachedServer && result.StatusCode == 200 && PalDefenderSucceeded(result.Body))
            {
                record.Status = "delivered";
                record.Result = result.Body;
                record.UpdatedUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
                WriteDelivery(path, record);
                Log("DELIVERY", "OK delivery=" + deliveryId + " player=" + playerId + " item=" + itemId + " count=" + count + ".");
                return "OK delivery=" + deliveryId + " status=delivered";
            }

            var definitelyRejected = result.ReachedServer && result.StatusCode >= 400 && result.StatusCode < 500;
            record.Status = definitelyRejected ? "failed" : "uncertain";
            record.Result = result.Error + " " + result.Body;
            record.UpdatedUtc = DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture);
            WriteDelivery(path, record);

            var code = definitelyRejected ? "backend_rejected" : "backend_uncertain";
            Log("DELIVERY", "ERROR delivery=" + deliveryId + " code=" + code + ".");
            return "ERROR delivery=" + deliveryId + " code=" + code + " message=" +
                   OneLine(string.IsNullOrWhiteSpace(result.Error) ? result.Body : result.Error);
        }
    }

    private static string ExecuteShutdown(string arguments)
    {
        var firstSpace = arguments.IndexOf(' ');
        var waitText = firstSpace < 0 ? arguments : arguments.Substring(0, firstSpace);
        var message = firstSpace < 0 ? "Server is shutting down" : arguments.Substring(firstSpace + 1).Trim();
        int wait;
        if (!int.TryParse(waitText, NumberStyles.None, CultureInfo.InvariantCulture, out wait) ||
            wait < 0 ||
            wait > 3600)
        {
            return "ERROR code=invalid_waittime";
        }

        return PalRestCommand(
            "/v1/api/shutdown",
            new Dictionary<string, object>
            {
                { "waittime", wait },
                { "message", message }
            });
    }

    private static string PalRestCommand(string path, Dictionary<string, object> body)
    {
        var result = SendHttp(
            "POST",
            _palRestUrl + path,
            Json.Serialize(body),
            BasicAuthorization(_palRestUser, _palRestPassword));
        if (result.ReachedServer && result.StatusCode >= 200 && result.StatusCode < 300)
        {
            return "OK status=accepted";
        }

        return "ERROR code=pal_rest_failed message=" +
               OneLine(string.IsNullOrWhiteSpace(result.Error) ? result.Body : result.Error);
    }

    private static string PalRestGet(string path)
    {
        var result = SendHttp(
            "GET",
            _palRestUrl + path,
            null,
            BasicAuthorization(_palRestUser, _palRestPassword));
        if (result.ReachedServer && result.StatusCode >= 200 && result.StatusCode < 300)
        {
            return OneLine(result.Body);
        }

        return "ERROR code=pal_rest_failed message=" +
               OneLine(string.IsNullOrWhiteSpace(result.Error) ? result.Body : result.Error);
    }

    private static string ExecuteNativeRcon(string command)
    {
        try
        {
            using (var client = new TcpClient())
            {
                client.ReceiveTimeout = 2500;
                client.SendTimeout = 2500;
                client.Connect(_nativeHost, _nativePort);
                using (var stream = client.GetStream())
                {
                    const int authId = 1101;
                    const int commandId = 1102;
                    const int terminatorId = 1103;
                    WritePacket(stream, authId, ServerDataAuth, _password);

                    var authenticated = false;
                    for (var index = 0; index < 4; index++)
                    {
                        var authResponse = ReadPacket(stream);
                        if (authResponse == null)
                        {
                            break;
                        }
                        if (authResponse.Type == ServerDataAuthResponse)
                        {
                            if (authResponse.RequestId == -1)
                            {
                                return "ERROR code=native_rcon_auth_failed";
                            }
                            if (authResponse.RequestId == authId)
                            {
                                authenticated = true;
                                break;
                            }
                        }
                    }

                    if (!authenticated)
                    {
                        return "ERROR code=native_rcon_auth_failed";
                    }

                    WritePacket(stream, commandId, ServerDataExecCommand, command);
                    WritePacket(stream, terminatorId, ServerDataExecCommand, "");
                    var response = new StringBuilder();
                    while (true)
                    {
                        RconPacket packet;
                        try
                        {
                            packet = ReadPacket(stream);
                        }
                        catch (IOException)
                        {
                            break;
                        }

                        if (packet == null || packet.RequestId == terminatorId)
                        {
                            break;
                        }
                        if (packet.RequestId == commandId)
                        {
                            response.Append(packet.Body);
                        }
                    }

                    return response.Length == 0 ? "OK status=accepted" : response.ToString();
                }
            }
        }
        catch (Exception ex)
        {
            return "ERROR code=native_rcon_unavailable message=" + OneLine(ex.Message);
        }
    }

    private static Dictionary<string, string> ParseNamedArguments(string input)
    {
        var tokens = Tokenize(input);
        var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        for (var index = 0; index < tokens.Count; index++)
        {
            var token = tokens[index];
            if (!token.StartsWith("--", StringComparison.Ordinal) || token.Length < 3)
            {
                throw new ArgumentException("Expected a named argument beginning with --.");
            }
            if (index + 1 >= tokens.Count)
            {
                throw new ArgumentException("Missing value for " + token + ".");
            }

            result[token.Substring(2)] = tokens[++index];
        }
        return result;
    }

    private static List<string> Tokenize(string input)
    {
        var tokens = new List<string>();
        var current = new StringBuilder();
        var quoted = false;
        var escaping = false;

        foreach (var character in input)
        {
            if (escaping)
            {
                current.Append(character);
                escaping = false;
                continue;
            }
            if (character == '\\' && quoted)
            {
                escaping = true;
                continue;
            }
            if (character == '"')
            {
                quoted = !quoted;
                continue;
            }
            if (char.IsWhiteSpace(character) && !quoted)
            {
                if (current.Length > 0)
                {
                    tokens.Add(current.ToString());
                    current.Length = 0;
                }
                continue;
            }
            current.Append(character);
        }

        if (quoted)
        {
            throw new ArgumentException("Unterminated quoted argument.");
        }
        if (escaping)
        {
            current.Append('\\');
        }
        if (current.Length > 0)
        {
            tokens.Add(current.ToString());
        }
        return tokens;
    }

    private static string LoadPalDefenderToken()
    {
        if (!string.IsNullOrWhiteSpace(_palDefenderToken))
        {
            return _palDefenderToken.Trim();
        }

        try
        {
            if (!File.Exists(_palDefenderTokenFile))
            {
                return "";
            }

            var content = File.ReadAllText(_palDefenderTokenFile, Encoding.UTF8).Trim();
            if (!content.StartsWith("{", StringComparison.Ordinal))
            {
                return content;
            }

            var parsed = Json.Deserialize<Dictionary<string, object>>(content);
            object token;
            return parsed != null && parsed.TryGetValue("Token", out token)
                ? Convert.ToString(token, CultureInfo.InvariantCulture)
                : "";
        }
        catch (Exception ex)
        {
            Log("ERROR", "Unable to load PalDefender token: " + ex.Message);
            return "";
        }
    }

    private static bool PalDefenderSucceeded(string body)
    {
        try
        {
            var response = Json.Deserialize<Dictionary<string, object>>(body);
            object errors;
            return response != null &&
                   response.TryGetValue("Errors", out errors) &&
                   Convert.ToInt32(errors, CultureInfo.InvariantCulture) == 0;
        }
        catch
        {
            return false;
        }
    }

    private static HttpResult SendHttp(string method, string url, string json, string authorization)
    {
        var result = new HttpResult();
        try
        {
            var request = (HttpWebRequest)WebRequest.Create(url);
            request.Method = method;
            request.Timeout = 10000;
            request.ReadWriteTimeout = 10000;
            request.Accept = "application/json";
            if (!string.IsNullOrWhiteSpace(authorization))
            {
                request.Headers[HttpRequestHeader.Authorization] = authorization;
            }
            if (json != null)
            {
                var bytes = Encoding.UTF8.GetBytes(json);
                request.ContentType = "application/json";
                request.ContentLength = bytes.Length;
                using (var requestStream = request.GetRequestStream())
                {
                    requestStream.Write(bytes, 0, bytes.Length);
                }
            }

            using (var response = (HttpWebResponse)request.GetResponse())
            {
                result.ReachedServer = true;
                result.StatusCode = (int)response.StatusCode;
                result.Body = ReadResponseBody(response);
            }
        }
        catch (WebException ex)
        {
            var response = ex.Response as HttpWebResponse;
            if (response != null)
            {
                using (response)
                {
                    result.ReachedServer = true;
                    result.StatusCode = (int)response.StatusCode;
                    result.Body = ReadResponseBody(response);
                }
            }
            result.Error = ex.Message;
        }
        catch (Exception ex)
        {
            result.Error = ex.Message;
        }
        return result;
    }

    private static string ReadResponseBody(HttpWebResponse response)
    {
        var stream = response.GetResponseStream();
        if (stream == null)
        {
            return "";
        }
        using (stream)
        using (var reader = new StreamReader(stream, Encoding.UTF8))
        {
            return reader.ReadToEnd();
        }
    }

    private static string BasicAuthorization(string user, string password)
    {
        return "Basic " + Convert.ToBase64String(Encoding.UTF8.GetBytes(user + ":" + password));
    }

    private static string GetDeliveryPath(string deliveryId)
    {
        using (var sha = SHA256.Create())
        {
            var hash = sha.ComputeHash(Encoding.UTF8.GetBytes(deliveryId));
            var name = BitConverter.ToString(hash).Replace("-", "").ToLowerInvariant() + ".json";
            return Path.Combine(_ledgerDirectory, name);
        }
    }

    private static DeliveryRecord ReadDelivery(string path)
    {
        try
        {
            return File.Exists(path)
                ? Json.Deserialize<DeliveryRecord>(File.ReadAllText(path, Encoding.UTF8))
                : null;
        }
        catch (Exception ex)
        {
            Log("ERROR", "Unable to read delivery ledger " + path + ": " + ex.Message);
            return new DeliveryRecord { Status = "uncertain" };
        }
    }

    private static void WriteDelivery(string path, DeliveryRecord record)
    {
        var temporary = path + ".tmp";
        var bytes = new UTF8Encoding(false).GetBytes(Json.Serialize(record));
        using (var stream = new FileStream(
            temporary,
            FileMode.Create,
            FileAccess.Write,
            FileShare.None,
            4096,
            FileOptions.WriteThrough))
        {
            stream.Write(bytes, 0, bytes.Length);
            stream.Flush(true);
        }

        if (File.Exists(path))
        {
            File.Replace(temporary, path, null);
        }
        else
        {
            File.Move(temporary, path);
        }
    }

    private static RconPacket ReadPacket(Stream stream)
    {
        var lengthBytes = ReadExact(stream, 4, true);
        if (lengthBytes == null)
        {
            return null;
        }

        var length = BitConverter.ToInt32(lengthBytes, 0);
        if (length < 10 || length > MaxPacketSize)
        {
            throw new InvalidDataException("Invalid Source RCON packet length: " + length + ".");
        }

        var payload = ReadExact(stream, length, false);
        if (payload[length - 2] != 0 || payload[length - 1] != 0)
        {
            throw new InvalidDataException("Source RCON packet is missing terminators.");
        }

        return new RconPacket
        {
            RequestId = BitConverter.ToInt32(payload, 0),
            Type = BitConverter.ToInt32(payload, 4),
            Body = Encoding.UTF8.GetString(payload, 8, length - 10)
        };
    }

    private static byte[] ReadExact(Stream stream, int count, bool allowCleanEnd)
    {
        var buffer = new byte[count];
        var offset = 0;
        while (offset < count)
        {
            var read = stream.Read(buffer, offset, count - offset);
            if (read == 0)
            {
                if (allowCleanEnd && offset == 0)
                {
                    return null;
                }
                throw new EndOfStreamException("Unexpected end of Source RCON stream.");
            }
            offset += read;
        }
        return buffer;
    }

    private static void WriteResponse(Stream stream, int requestId, string body)
    {
        var chunks = SplitUtf8(body ?? "", MaxBodyBytes);
        if (chunks.Count == 0)
        {
            chunks.Add("");
        }
        foreach (var chunk in chunks)
        {
            WritePacket(stream, requestId, ServerDataResponseValue, chunk);
        }
    }

    private static void WritePacket(Stream stream, int requestId, int type, string body)
    {
        var bodyBytes = Encoding.UTF8.GetBytes(body ?? "");
        if (bodyBytes.Length > MaxBodyBytes)
        {
            throw new InvalidDataException("Source RCON response body exceeds one packet.");
        }

        var length = 10 + bodyBytes.Length;
        var packet = new byte[4 + length];
        Buffer.BlockCopy(BitConverter.GetBytes(length), 0, packet, 0, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(requestId), 0, packet, 4, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(type), 0, packet, 8, 4);
        Buffer.BlockCopy(bodyBytes, 0, packet, 12, bodyBytes.Length);
        packet[packet.Length - 2] = 0;
        packet[packet.Length - 1] = 0;
        stream.Write(packet, 0, packet.Length);
        stream.Flush();
    }

    private static List<string> SplitUtf8(string value, int maximumBytes)
    {
        var chunks = new List<string>();
        var current = new StringBuilder();
        var currentBytes = 0;
        for (var index = 0; index < value.Length; index++)
        {
            var unit = value[index].ToString();
            if (char.IsHighSurrogate(value[index]) &&
                index + 1 < value.Length &&
                char.IsLowSurrogate(value[index + 1]))
            {
                unit += value[++index];
            }

            var characterBytes = Encoding.UTF8.GetByteCount(unit);
            if (current.Length > 0 && currentBytes + characterBytes > maximumBytes)
            {
                chunks.Add(current.ToString());
                current.Length = 0;
                currentBytes = 0;
            }
            current.Append(unit);
            currentBytes += characterBytes;
        }
        if (current.Length > 0)
        {
            chunks.Add(current.ToString());
        }
        return chunks;
    }

    private static bool ConstantTimeEquals(string left, string right)
    {
        var leftBytes = Encoding.UTF8.GetBytes(left ?? "");
        var rightBytes = Encoding.UTF8.GetBytes(right ?? "");
        var difference = leftBytes.Length ^ rightBytes.Length;
        var maximum = Math.Max(leftBytes.Length, rightBytes.Length);
        for (var index = 0; index < maximum; index++)
        {
            var leftByte = index < leftBytes.Length ? leftBytes[index] : (byte)0;
            var rightByte = index < rightBytes.Length ? rightBytes[index] : (byte)0;
            difference |= leftByte ^ rightByte;
        }
        return difference == 0;
    }

    private static void Log(string level, string message)
    {
        var line = DateTime.UtcNow.ToString("yyyy-MM-dd HH:mm:ss'Z'", CultureInfo.InvariantCulture) +
                   " [PALBRIDGE][" + level + "] " + OneLine(message);
        lock (LogLock)
        {
            Console.WriteLine(line);
            if (_logWriter != null)
            {
                _logWriter.WriteLine(line);
            }
        }
    }

    private static string SanitizeForLog(string value)
    {
        if (value.StartsWith("palbridge give ", StringComparison.OrdinalIgnoreCase))
        {
            return value;
        }
        return OneLine(value);
    }

    private static string OneLine(string value)
    {
        return (value ?? "").Replace("\r", " ").Replace("\n", " ").Trim();
    }

    private static string Env(string name, string fallback)
    {
        var value = Environment.GetEnvironmentVariable(name);
        return string.IsNullOrWhiteSpace(value) ? fallback : value;
    }

    private static int IntEnv(string name, int fallback, int minimum, int maximum)
    {
        int value;
        return int.TryParse(Env(name, ""), NumberStyles.None, CultureInfo.InvariantCulture, out value) &&
               value >= minimum &&
               value <= maximum
            ? value
            : fallback;
    }

    private static bool BoolEnv(string name, bool fallback)
    {
        var value = Env(name, "").Trim().ToLowerInvariant();
        if (value == "1" || value == "true" || value == "yes" || value == "on")
        {
            return true;
        }
        if (value == "0" || value == "false" || value == "no" || value == "off")
        {
            return false;
        }
        return fallback;
    }
}

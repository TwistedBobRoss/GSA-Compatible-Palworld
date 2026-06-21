using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

internal static class GsaRconBridgeTests
{
    private const string Password = "test-password";

    private sealed class Packet
    {
        public int Id;
        public int Type;
        public string Body;
    }

    private sealed class FakeHttpServer : IDisposable
    {
        private readonly TcpListener _listener;
        private readonly Thread _thread;
        private volatile bool _stopping;

        public int Port { get; private set; }
        public string LastAnnounceBody;

        public FakeHttpServer()
        {
            _listener = new TcpListener(IPAddress.Loopback, 0);
            _listener.Start();
            Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
            _thread = new Thread(Run);
            _thread.IsBackground = true;
            _thread.Start();
        }

        private void Run()
        {
            while (!_stopping)
            {
                try
                {
                    var client = _listener.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(Handle, client);
                }
                catch (SocketException)
                {
                    if (!_stopping)
                    {
                        throw;
                    }
                }
            }
        }

        private void Handle(object state)
        {
            using (var client = (TcpClient)state)
            using (var stream = client.GetStream())
            {
                var headers = ReadHeaders(stream);
                var lines = headers.Split(new[] { "\r\n" }, StringSplitOptions.None);
                var request = lines[0].Split(' ');
                var path = request.Length > 1 ? request[1] : "/";
                var contentLength = 0;
                foreach (var line in lines)
                {
                    if (line.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                    {
                        int.TryParse(line.Substring(line.IndexOf(':') + 1).Trim(), out contentLength);
                    }
                }

                var bodyBytes = ReadExact(stream, contentLength);
                var body = Encoding.UTF8.GetString(bodyBytes);
                string response;
                if (path == "/v1/api/players")
                {
                    response = "{\"players\":[{\"name\":\"Test Pal\",\"accountName\":\"tester\",\"playerId\":\"AFAFD830000000000000000000000000\",\"userId\":\"steam_123\"}]}";
                }
                else if (path == "/v1/api/announce")
                {
                    LastAnnounceBody = body;
                    response = "{}";
                }
                else if (path == "/v1/api/info")
                {
                    response = "{\"data\":\"" + new string('x', 9000) + "\"}";
                }
                else
                {
                    response = "{}";
                }

                var bytes = Encoding.UTF8.GetBytes(response);
                var responseHeaders = Encoding.ASCII.GetBytes(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " +
                    bytes.Length.ToString(CultureInfo.InvariantCulture) +
                    "\r\nConnection: close\r\n\r\n");
                stream.Write(responseHeaders, 0, responseHeaders.Length);
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush();
            }
        }

        private static string ReadHeaders(Stream stream)
        {
            var bytes = new List<byte>();
            while (bytes.Count < 32768)
            {
                var value = stream.ReadByte();
                if (value < 0)
                {
                    throw new EndOfStreamException();
                }
                bytes.Add((byte)value);
                var count = bytes.Count;
                if (count >= 4 &&
                    bytes[count - 4] == 13 &&
                    bytes[count - 3] == 10 &&
                    bytes[count - 2] == 13 &&
                    bytes[count - 1] == 10)
                {
                    return Encoding.ASCII.GetString(bytes.ToArray());
                }
            }
            throw new InvalidDataException("HTTP headers were too large.");
        }

        private static byte[] ReadExact(Stream stream, int count)
        {
            var bytes = new byte[count];
            var offset = 0;
            while (offset < count)
            {
                var read = stream.Read(bytes, offset, count - offset);
                if (read == 0)
                {
                    throw new EndOfStreamException();
                }
                offset += read;
            }
            return bytes;
        }

        public void Dispose()
        {
            _stopping = true;
            _listener.Stop();
            _thread.Join(2000);
        }
    }

    private sealed class FakeQueueWorker : IDisposable
    {
        private readonly string _queueRoot;
        private readonly Thread _thread;
        private volatile bool _stopping;

        public int GiveCount;
        public string LastRequest;

        public FakeQueueWorker(string queueRoot)
        {
            _queueRoot = queueRoot;
            Directory.CreateDirectory(Path.Combine(_queueRoot, "in"));
            Directory.CreateDirectory(Path.Combine(_queueRoot, "work"));
            Directory.CreateDirectory(Path.Combine(_queueRoot, "out"));
            _thread = new Thread(Run);
            _thread.IsBackground = true;
            _thread.Start();
        }

        private void Run()
        {
            while (!_stopping)
            {
                foreach (var requestPath in Directory.GetFiles(Path.Combine(_queueRoot, "in"), "*.request"))
                {
                    var name = Path.GetFileName(requestPath);
                    var workPath = Path.Combine(_queueRoot, "work", name);
                    try
                    {
                        File.Move(requestPath, workPath);
                    }
                    catch
                    {
                        continue;
                    }

                    var request = Parse(File.ReadAllLines(workPath, Encoding.UTF8));
                    LastRequest = File.ReadAllText(workPath, Encoding.UTF8);
                    Interlocked.Increment(ref GiveCount);
                    var responsePath = Path.Combine(
                        _queueRoot,
                        "out",
                        Path.GetFileNameWithoutExtension(name) + ".response");
                    var response =
                        "version=1\r\n" +
                        "delivery=" + request["delivery"] + "\r\n" +
                        "character=" + request["character"] + "\r\n" +
                        "player=" + request["player"] + "\r\n" +
                        "item=" + request["item"] + "\r\n" +
                        "count=" + request["count"] + "\r\n" +
                        "status=delivered\r\n" +
                        "code=success\r\n" +
                        "message=Test worker delivered item\r\n";
                    File.WriteAllText(responsePath + ".tmp", response, new UTF8Encoding(false));
                    File.Move(responsePath + ".tmp", responsePath);
                    File.Delete(workPath);
                }
                Thread.Sleep(25);
            }
        }

        private static Dictionary<string, string> Parse(string[] lines)
        {
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var line in lines)
            {
                var split = line.IndexOf('=');
                if (split > 0)
                {
                    result[line.Substring(0, split)] = line.Substring(split + 1);
                }
            }
            return result;
        }

        public void Dispose()
        {
            _stopping = true;
            _thread.Join(2000);
        }
    }

    private sealed class RconClient : IDisposable
    {
        private readonly TcpClient _client;
        private readonly NetworkStream _stream;

        public RconClient(int port, string password, bool fragmentedAuth)
        {
            _client = new TcpClient();
            _client.ReceiveTimeout = 2000;
            _client.SendTimeout = 2000;
            _client.Connect(IPAddress.Loopback, port);
            _stream = _client.GetStream();

            var auth = EncodePacket(50, 3, password);
            if (fragmentedAuth)
            {
                foreach (var value in auth)
                {
                    _stream.WriteByte(value);
                }
                _stream.Flush();
            }
            else
            {
                _stream.Write(auth, 0, auth.Length);
                _stream.Flush();
            }

            var response = ReadPacket(_stream);
            Assert(response.Id == 50 && response.Type == 2, "Expected Source RCON auth response.");
        }

        public string Execute(string command)
        {
            var bytes = EncodePacket(60, 2, command);
            _stream.Write(bytes, 0, bytes.Length);
            _stream.Flush();
            return ReadResponseBody(60);
        }

        public string ExecuteSingle(string command)
        {
            var bytes = EncodePacket(63, 2, command);
            _stream.Write(bytes, 0, bytes.Length);
            _stream.Flush();
            var response = ReadPacket(_stream);
            Assert(response.Id == 63 && response.Type == 0, "Expected one Source RCON response packet.");
            return response.Body;
        }

        public Packet[] ExecuteCombined(string first, string second)
        {
            var one = EncodePacket(61, 2, first);
            var two = EncodePacket(62, 2, second);
            var combined = new byte[one.Length + two.Length];
            Buffer.BlockCopy(one, 0, combined, 0, one.Length);
            Buffer.BlockCopy(two, 0, combined, one.Length, two.Length);
            _stream.Write(combined, 0, combined.Length);
            _stream.Flush();
            return new[] { ReadPacket(_stream), ReadPacket(_stream) };
        }

        private string ReadResponseBody(int id)
        {
            var output = new StringBuilder();
            while (true)
            {
                try
                {
                    var packet = ReadPacket(_stream);
                    if (packet.Id == id)
                    {
                        output.Append(packet.Body);
                    }
                }
                catch (IOException)
                {
                    break;
                }
            }
            return output.ToString();
        }

        public void Dispose()
        {
            _stream.Dispose();
            _client.Dispose();
        }
    }

    public static int Main(string[] args)
    {
        if (args.Length != 1)
        {
            Console.Error.WriteLine("Usage: GsaRconBridgeTests.exe <bridge-exe>");
            return 2;
        }

        var root = Path.Combine(Path.GetTempPath(), "PalBridgeTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(root);
        Process bridge = null;
        try
        {
            using (var fake = new FakeHttpServer())
            using (var queue = new FakeQueueWorker(Path.Combine(root, "queue")))
            {
                var port = GetFreePort();

                bridge = StartBridge(args[0], root, port, fake.Port);
                WaitForPort(port);

                TestWrongPassword(port);

                using (var client = new RconClient(port, Password, true))
                {
                    Assert(client.Execute("palbridge ping").Contains("OK status=ready"), "Ping failed.");

                    var combined = client.ExecuteCombined("palbridge ping", "palbridge version");
                    Assert(combined[0].Id == 61 && combined[0].Body.Contains("status=ready"), "Combined ping failed.");
                    Assert(combined[1].Id == 62 && combined[1].Body.Contains("version=0.2.0"), "Combined version failed.");

                    var give = "palbridge give --delivery \"delivery-1\" --character \"AFAFD830000000000000000000000000\" --player \"steam_123\" --item \"Wood\" --count 5";
                    Assert(client.Execute(give).Contains("status=delivered"), "Initial delivery failed.");
                    Assert(queue.GiveCount == 1, "Initial delivery did not call the mod queue exactly once.");
                    Assert(queue.LastRequest.Contains("character=AFAFD830000000000000000000000000"), "Character ID was not queued.");
                    Assert(queue.LastRequest.Contains("player=steam_123"), "Player ID was not queued.");
                    Assert(queue.LastRequest.Contains("item=Wood"), "Item ID was not queued.");

                    Assert(client.Execute(give).Contains("status=already_delivered"), "Duplicate delivery was not recognized.");
                    Assert(queue.GiveCount == 1, "Duplicate delivery called the mod queue.");

                    var mismatch = "palbridge give --delivery \"delivery-2\" --character \"AFAFD830000000000000000000000000\" --player \"steam_999\" --item \"Wood\" --count 1";
                    Assert(client.Execute(mismatch).Contains("code=identity_mismatch"), "Character/platform mismatch was not rejected.");
                    Assert(queue.GiveCount == 1, "Mismatched identity reached the mod queue.");

                    Assert(client.Execute("Broadcast Héllo 世界").Contains("OK status=accepted"), "Unicode broadcast failed.");
                    Assert(fake.LastAnnounceBody.Contains("Héllo 世界"), "Unicode body was corrupted.");

                    var longResponse = client.Execute("Info");
                    Assert(longResponse.Length > 9000, "Long response was not reassembled from multiple packets.");
                }

                TestParallelClients(port);

                StopBridge(bridge);
                bridge = StartBridge(args[0], root, port, fake.Port);
                WaitForPort(port);
                using (var client = new RconClient(port, Password, false))
                {
                    var give = "palbridge give --delivery \"delivery-1\" --character \"AFAFD830000000000000000000000000\" --player \"steam_123\" --item \"Wood\" --count 5";
                    Assert(client.Execute(give).Contains("status=already_delivered"), "Ledger did not survive restart.");
                    Assert(queue.GiveCount == 1, "Restart retry duplicated the mod delivery.");
                }
            }

            Console.WriteLine("Authentication and fragmented reads: PASS");
            Console.WriteLine("Combined and persistent commands: PASS");
            Console.WriteLine("REST identity validation, mod queue delivery, and duplicate protection: PASS");
            Console.WriteLine("UTF-8 and multi-packet responses: PASS");
            Console.WriteLine("Parallel clients and restart retry: PASS");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex);
            return 1;
        }
        finally
        {
            StopBridge(bridge);
            try
            {
                Directory.Delete(root, true);
            }
            catch
            {
            }
        }
    }

    private static Process StartBridge(string executable, string root, int port, int backendPort)
    {
        Environment.SetEnvironmentVariable("PAL_ADMIN_PASSWORD", Password);
        Environment.SetEnvironmentVariable("PAL_RCON_PORT", port.ToString(CultureInfo.InvariantCulture));
        Environment.SetEnvironmentVariable("PAL_BRIDGE_LISTEN_ADDRESS", "127.0.0.1");
        Environment.SetEnvironmentVariable("PAL_BRIDGE_PROXY_NATIVE", "false");
        Environment.SetEnvironmentVariable("PAL_BRIDGE_AUTH_EMPTY_RESPONSE", "false");
        Environment.SetEnvironmentVariable("PAL_REST_URL", "http://127.0.0.1:" + backendPort);
        Environment.SetEnvironmentVariable("PAL_BRIDGE_QUEUE", Path.Combine(root, "queue"));
        Environment.SetEnvironmentVariable("PAL_BRIDGE_DELIVERY_TIMEOUT", "3");
        Environment.SetEnvironmentVariable("PAL_BRIDGE_LEDGER", Path.Combine(root, "ledger"));
        Environment.SetEnvironmentVariable("PAL_BRIDGE_LOG", Path.Combine(root, "bridge.log"));

        var start = new ProcessStartInfo(executable);
        start.UseShellExecute = false;
        start.CreateNoWindow = true;
        start.RedirectStandardOutput = true;
        start.RedirectStandardError = true;
        var process = Process.Start(start);
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        return process;
    }

    private static void StopBridge(Process process)
    {
        if (process == null)
        {
            return;
        }
        try
        {
            if (!process.HasExited)
            {
                process.Kill();
                process.WaitForExit(3000);
            }
            process.Dispose();
        }
        catch
        {
        }
    }

    private static void TestWrongPassword(int port)
    {
        using (var client = new TcpClient())
        {
            client.ReceiveTimeout = 2000;
            client.Connect(IPAddress.Loopback, port);
            using (var stream = client.GetStream())
            {
                var packet = EncodePacket(45, 3, "wrong");
                stream.Write(packet, 0, packet.Length);
                stream.Flush();
                var response = ReadPacket(stream);
                Assert(response.Id == -1 && response.Type == 2, "Incorrect password did not receive auth failure.");
            }
        }
    }

    private static void TestParallelClients(int port)
    {
        Exception failure = null;
        var threads = new List<Thread>();
        for (var index = 0; index < 6; index++)
        {
            var thread = new Thread(delegate()
            {
                try
                {
                    using (var client = new RconClient(port, Password, false))
                    {
                        Assert(client.ExecuteSingle("palbridge ping").Contains("status=ready"), "Parallel ping failed.");
                    }
                }
                catch (Exception ex)
                {
                    failure = ex;
                }
            });
            threads.Add(thread);
            thread.Start();
        }
        foreach (var thread in threads)
        {
            thread.Join();
        }
        if (failure != null)
        {
            throw failure;
        }
    }

    private static int GetFreePort()
    {
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        var port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static void WaitForPort(int port)
    {
        for (var attempt = 0; attempt < 100; attempt++)
        {
            try
            {
                using (var client = new TcpClient())
                {
                    client.Connect(IPAddress.Loopback, port);
                    return;
                }
            }
            catch
            {
                Thread.Sleep(50);
            }
        }
        throw new TimeoutException("Bridge did not start listening.");
    }

    private static byte[] EncodePacket(int id, int type, string body)
    {
        var bodyBytes = Encoding.UTF8.GetBytes(body);
        var length = 10 + bodyBytes.Length;
        var bytes = new byte[4 + length];
        Buffer.BlockCopy(BitConverter.GetBytes(length), 0, bytes, 0, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(id), 0, bytes, 4, 4);
        Buffer.BlockCopy(BitConverter.GetBytes(type), 0, bytes, 8, 4);
        Buffer.BlockCopy(bodyBytes, 0, bytes, 12, bodyBytes.Length);
        return bytes;
    }

    private static Packet ReadPacket(Stream stream)
    {
        var lengthBytes = ReadExact(stream, 4);
        var length = BitConverter.ToInt32(lengthBytes, 0);
        var payload = ReadExact(stream, length);
        return new Packet
        {
            Id = BitConverter.ToInt32(payload, 0),
            Type = BitConverter.ToInt32(payload, 4),
            Body = Encoding.UTF8.GetString(payload, 8, length - 10)
        };
    }

    private static byte[] ReadExact(Stream stream, int count)
    {
        var bytes = new byte[count];
        var offset = 0;
        while (offset < count)
        {
            var read = stream.Read(bytes, offset, count - offset);
            if (read == 0)
            {
                throw new EndOfStreamException();
            }
            offset += read;
        }
        return bytes;
    }

    private static void Assert(bool condition, string message)
    {
        if (!condition)
        {
            throw new InvalidOperationException(message);
        }
    }
}

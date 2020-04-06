namespace Mail;

enum SmtpRole: string {
    Client = "Client";
    Server = "Server";
}

type SmtpLog = shape('role' => SmtpRole, 'content' => string);

type SmtpReply = shape(
    'code' => int,
    'message' => ?string,
);

class SmtpClient {
    private ?resource $smtp_conn = null;
    private int $timeout = 30; // in seconds
    private vec<SmtpLog> $history = vec[];
    private bool $debug = true;
    public static string $lineEnd = "\r\n";
    private string $hostName = "";

    public async function genConnect(string $host, int $port): Awaitable<bool> {
        $options = varray[];
        $socket_context = \stream_context_create($options);

        $errno = 0;
        $errstr = '';
        $smtp_conn = \stream_socket_client(
            'smtp.gmail.com:587',
            inout $errno,
            inout $errstr,
            (float)($this->timeout),
            \STREAM_CLIENT_CONNECT,
            $socket_context,
        );

        if (\is_resource($smtp_conn)) {
            $this->smtp_conn = $smtp_conn;
            $this->hostName = $host;
            return true;
        }

        return false;
    }

    public async function genReadWelcome(): Awaitable<bool> {
        $_welcome_message = await $this->genReadLines();
        // TODO: process $_welcome_message
        return true;
    }

    public async function genSendHello(string $host_name): Awaitable<bool> {
        $_hello_reply = await $this->genSendAndReadLines('EHLO'.' '.$host_name);
        // TODO: process $_hello_reply
        return true;
    }

    private async function genReadLines(): Awaitable<vec<string>> {
        $smtp_conn = nullthrows($this->smtp_conn);
        \stream_set_timeout($smtp_conn, $this->timeout);

        $lines = vec[];
        $selR = varray[$this->smtp_conn];
        $selW = null;
        while (\is_resource($smtp_conn) && !\feof($smtp_conn)) {
            if (
                !\stream_select(
                    inout $selR,
                    inout $selW,
                    inout $selW,
                    $this->timeout,
                )
            ) {
                \Log\MainLogger::log(\Log\LogLevel::INFO, 'Timeout');
                break;
            }

            $line = \fgets($smtp_conn, 1024);
            $lines[] = $line;

            // If response is only 3 chars (not valid, but RFC5321 S4.2 says it must be handled),
            // or 4th character is a space, we are done reading, break the loop
            if (
                \HH\Lib\Str\length($line) <= 3 ||
                \HH\Lib\Str\slice($line, 3, 1) === ' '
            ) {
                break;
            }
        }

        $this->logLines($lines);

        return $lines;
    }

    private async function genSend(string $data): Awaitable<bool> {
        $smtp_conn = nullthrows($this->smtp_conn);

        $data = $data.self::$lineEnd;
        $bytes_written = \fwrite($smtp_conn, $data);
        if ($bytes_written === 0) {
            return false;
        }

        $this->logHistory(SmtpRole::Client, $data);

        return true;
    }

    private async function genSendAndReadLines(
        string $data,
    ): Awaitable<?vec<string>> {
        $smtp_conn = nullthrows($this->smtp_conn);
        $succeeded = await $this->genSend($data);
        if (!$succeeded) {
            return null;
        }

        return await $this->genReadLines();
    }

    private async function genSendAndExpect(
        string $data,
        int $expected_reply_code,
    ): Awaitable<bool> {
        $smtp_conn = nullthrows($this->smtp_conn);
        $reply = await $this->genSendAndReadLines($data);

        if ($reply === null) {
            return false;
        }

        $reply = await $this->genParseReply($reply);
        $reply_code = \HH\Lib\C\firstx($reply)['code'];
        if ($reply_code === $expected_reply_code) {
            return true;
        }
        return false;
    }

    private async function genSendAndExpectAny(
        string $data,
        keyset<int> $expected_reply_codes,
    ): Awaitable<bool> {
        $reply = await $this->genSendAndReadLines($data);
        if ($reply === null) {
            return false;
        }

        $reply = await $this->genParseReply($reply);
        $reply_code = \HH\Lib\C\firstx($reply)['code'];
        if (\HH\Lib\C\contains($expected_reply_codes, $reply_code)) {
            return true;
        }
        return false;
    }


    private async function genParseReply(
        vec<string> $lines,
    ): Awaitable<vec<SmtpReply>> {
        return \HH\Lib\Vec\map($lines, $line ==> {
            $pattern = re"/^([\d]{3})[ -](?:([\d]\\.[\d]\\.[\d]{1,2}) )?/";

            $captures = \HH\Lib\Regex\every_match($line, $pattern);
            $capture = \HH\Lib\C\first($captures);
            if ($capture !== null) {
                return shape(
                    'code' => (int)$capture[1],
                    'message' => $capture[2],
                );
            }
            return null;
        })
            |> \HH\Lib\Vec\filter_nulls($$);
    }

    public async function genStartTLS(): Awaitable<bool> {
        $smtp_conn = nullthrows($this->smtp_conn);
        $succeeded = await $this->genSendAndExpect('STARTTLS', 220);
        if ($succeeded) {
            $crypto_method = \STREAM_CRYPTO_METHOD_TLS_CLIENT;
            $crypto_method |= \STREAM_CRYPTO_METHOD_TLSv1_2_CLIENT;

            $crypto_ok = \stream_socket_enable_crypto(
                $smtp_conn,
                true,
                $crypto_method,
            );

            return $crypto_ok;
        }

        return false;
    }

    public async function genAuthenticate(
        string $user_name,
        string $password,
    ): Awaitable<bool> {
        $smtp_conn = nullthrows($this->smtp_conn);
        $succeeded = await $this->genSendAndExpect('AUTH LOGIN', 334);
        if (!$succeeded) {
            return false;
        }

        $succeeded = await $this->genSendAndExpect(
            \base64_encode($user_name),
            334,
        );
        if (!$succeeded) {
            return false;
        }

        $succeeded = await $this->genSendAndExpect(
            \base64_encode($password),
            235,
        );
        if (!$succeeded) {
            return false;
        }

        return true;
    }

    public async function genSendData(string $data): Awaitable<bool> {
        $smtp_conn = nullthrows($this->smtp_conn);
        $succeeded = await $this->genSendAndExpect('DATA', 354);
        if (!$succeeded) {
            return false;
        }

        await $this->genSend($data);

        // Ending the session.
        $succeeded = await $this->genSendAndExpect('.', 250);
        if (!$succeeded) {
            return false;
        }
        return true;
    }

    public async function genSendFrom(string $from): Awaitable<bool> {
        $smtp_conn = nullthrows($this->smtp_conn);
        $succeeded = await $this->genSendAndExpect(
            'MAIL FROM:<'.$from.'>',
            250,
        );
        if (!$succeeded) {
            return false;
        }
        return true;
    }

    public async function genSendRecipient(string $recipient): Awaitable<bool> {
        $smtp_conn = nullthrows($this->smtp_conn);
        $succeeded = await $this->genSendAndExpectAny(
            'RCPT TO:<'.$recipient.'>',
            keyset[250, 251],
        );
        if (!$succeeded) {
            return false;
        }
        return true;
    }

    public async function genSendQuit(): Awaitable<bool> {
        $smtp_conn = nullthrows($this->smtp_conn);
        $succeeded = await $this->genSendAndExpect('QUIT', 221);
        if (!$succeeded) {
            return false;
        }
        \fclose($smtp_conn);

        $this->smtp_conn = null;
        $this->hostName = "";
        return true;
    }

    private function logLines(vec<string> $lines): void {
        if ($this->debug) {
            \HH\Lib\Vec\map(
                $lines,
                $line ==> $this->logHistory(SmtpRole::Server, $line),
            );
        }
    }

    private function logHistory(SmtpRole $role, string $content): void {
        if ($this->debug) {
            \printf("%s: %s\n", $role, $content);

            $this->history[] = shape(
                'role' => SmtpRole::Client,
                'content' => (string)$content,
            );
        }
    }
}

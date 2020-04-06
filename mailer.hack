namespace Mail;

function nullthrows<T>(?T $value): T {
    if ($value === null) {
        throw new \Exception('Unexpected null.');
    }

    return $value;
}

type Address = shape(
    'address' => string,
    'name' => ?string,
);

class Mailer {
    private ?string $hostName = null;
    private ?int $port = null;

    private ?string $userName = null;
    private ?string $password = null;

    private ?Address $from = null;
    private ?vec<Address> $to = null;
    private ?vec<Address> $cc = null;
    private ?vec<Address> $bcc = null;
    private ?string $subject = null;

    private ?string $messageBodyPlain = null;
    private ?string $messageBodyHtml = null;

    private ?string $boundary = null;

    public function setHostName(string $hostName): Mailer {
        $this->hostName = $hostName;
        return $this;
    }

    public function setPort(int $port): Mailer {
        $this->port = $port;
        return $this;
    }

    public function setUserName(string $userName): Mailer {
        $this->userName = $userName;
        return $this;
    }

    public function setPassword(string $password): Mailer {
        $this->password = $password;
        return $this;
    }

    public function setFrom(string $from, ?string $name = null): Mailer {
        $this->from = shape('address' => $from, 'name' => $name);
        return $this;
    }

    public function addTo(string $to, ?string $name = null): Mailer {
        if ($this->to === null) {
            $this->to = vec[];
        }

        $this->to[] = shape('address' => $to, 'name' => $name);
        return $this;
    }

    public function addCc(string $cc, ?string $name = null): Mailer {
        if ($this->cc === null) {
            $this->cc = vec[];
        }

        $this->cc[] = shape('address' => $cc, 'name' => $name);
        return $this;
    }

    public function addBcc(string $bcc, ?string $name = null): Mailer {
        if ($this->bcc === null) {
            $this->bcc = vec[];
        }

        $this->bcc[] = shape('address' => $bcc, 'name' => $name);
        return $this;
    }

    public function setSubject(string $subject): Mailer {
        $this->subject = $subject;
        return $this;
    }

    public function setMessageBodyPlain(string $messageBodyPlain): Mailer {
        $this->messageBodyPlain = $messageBodyPlain;
        return $this;
    }

    public function setMessageBodyHtml(string $messageBodyHtml): Mailer {
        $this->messageBodyHtml = $messageBodyHtml;
        return $this;
    }

    public async function genSend(): Awaitable<bool> {
        $smtp_client = new SmtpClient();

        $succeeded = await $smtp_client->genConnect(
            nullthrows($this->hostName),
            nullthrows($this->port),
        );
        if (!$succeeded) {
            return false;
        }

        $succeeded = await $smtp_client->genReadWelcome();
        if (!$succeeded) {
            return false;
        }

        $succeeded = await $smtp_client->genSendHello(
            nullthrows($this->hostName),
        );
        if (!$succeeded) {
            return false;
        }

        $succeeded = await $smtp_client->genStartTLS();
        if (!$succeeded) {
            return false;
        }

        $succeeded = await $smtp_client->genAuthenticate(
            nullthrows($this->userName),
            nullthrows($this->password),
        );
        if (!$succeeded) {
            return false;
        }

        $succeeded = await $smtp_client->genSendFrom(
            nullthrows($this->from)['address'],
        );
        if (!$succeeded) {
            return false;
        }

        $accepted_recipients = vec[];
        if ($this->to !== null) {
            $accepted_to = await \HH\Lib\Vec\map_async(
                $this->to,
                async $address ==> {
                    $succeeded = await $smtp_client->genSendRecipient(
                        $address['address'],
                    );
                },
            );

            $accepted_recipients = \HH\Lib\Vec\concat(
                $accepted_recipients,
                $accepted_to,
            );
        }

        if ($this->cc !== null) {
            $accepted_cc = await \HH\Lib\Vec\map_async(
                $this->cc,
                async $address ==> {
                    $succeeded = await $smtp_client->genSendRecipient(
                        $address['address'],
                    );
                },
            );

            $accepted_recipients = \HH\Lib\Vec\concat(
                $accepted_recipients,
                $accepted_cc,
            );
        }

        if ($this->bcc !== null) {
            $accepted_bcc = await \HH\Lib\Vec\map_async(
                $this->bcc,
                async $address ==> {
                    $succeeded = await $smtp_client->genSendRecipient(
                        $address['address'],
                    );
                },
            );

            $accepted_recipients = \HH\Lib\Vec\concat(
                $accepted_recipients,
                $accepted_bcc,
            );
        }

        // Expect to have at least 1 recipient
        if (\HH\Lib\C\is_empty($accepted_recipients)) {
            return false;
        }

        $header = $this->buildMessageHeader();
        $body = $this->buildMessageBody();

        $succeeded = await $smtp_client->genSendData($header.$body);
        if (!$succeeded) {
            return false;
        }

        $succeeded = await $smtp_client->genSendQuit();
        if (!$succeeded) {
            return false;
        }
        return true;
    }

    private function buildAddress(
        string $type,
        string $address,
        ?string $name,
    ): string {
        if ($name !== null) {
            return \HH\Lib\Str\format(
                "%s: \"%s\" <%s>",
                $type,
                $name,
                $address,
            ).
                SmtpClient::$lineEnd;
        } else {
            return \HH\Lib\Str\format("%s: <%s>", $type, $address).
                SmtpClient::$lineEnd;
        }
    }

    private function buildMessageHeader(): string {
        $this->boundary = 'hhvm-mailer_'.\uniqid();

        $header = '';
        if ($this->from !== null) {
            $header .= $this->buildAddress(
                'From',
                $this->from['address'],
                $this->from['name'],
            );
        }

        if ($this->to !== null) {
            $lines = \HH\Lib\Vec\map(
                $this->to,
                $address ==> $this->buildAddress(
                    'To',
                    $address['address'],
                    $address['name'],
                ),
            );

            foreach ($lines as $line) {
                $header .= $line;
            }
        }

        if ($this->cc !== null) {
            $lines = \HH\Lib\Vec\map(
                $this->cc,
                $address ==> $this->buildAddress(
                    'Cc',
                    $address['address'],
                    $address['name'],
                ),
            );

            foreach ($lines as $line) {
                $header .= $line;
            }
        }

        if ($this->subject !== null) {
            $header .= \HH\Lib\Str\format('Subject: %s', $this->subject).
                SmtpClient::$lineEnd;
        }

        $header .= "Content-Type: multipart/alternative;boundary=".
            $this->boundary.
            SmtpClient::$lineEnd;

        $header .= SmtpClient::$lineEnd;
        return $header;
    }

    private function buildMessageBody(): string {
        $body = '';
        $body .= "--".$this->boundary.SmtpClient::$lineEnd;
        $body .= "Content-type: text/plain;charset=utf-8".SmtpClient::$lineEnd;
        $body .= SmtpClient::$lineEnd;
        $body .= (string)($this->messageBodyPlain).SmtpClient::$lineEnd;
        $body .= SmtpClient::$lineEnd;

        $body .= "--".$this->boundary.SmtpClient::$lineEnd;
        $body .= "Content-type: text/html;charset=utf-8".SmtpClient::$lineEnd;
        $body .= SmtpClient::$lineEnd;
        $body .= (string)($this->messageBodyHtml).SmtpClient::$lineEnd;
        $body .= SmtpClient::$lineEnd;

        $body .= "--".$this->boundary."--";
        return $body;
    }
}

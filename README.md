# hhvm-mailer

Allow you to use HHVM to send email.

Current only support SMTP. Tested with gmail.

Usage:

    $mailer = (new \Mail\Mailer())->setHostName('smtp.gmail.com')
        ->setPort(587)
        ->setUserName('<YOUR_GMAIL_ADDRESS>')
        ->setPassword('<CHANGE_TO_YOUR_GMAIL_APP_PASSWORD>')
        ->setFrom('legol.chen@gmail.com', 'Jie Chen')
        ->addTo('legol.chen@gmail.com')
        ->addCc('jie.chen.80.1@gmail.com')
        ->setSubject('Hello Mail From hhvm-mailer')
        ->setMessageBodyPlain('plain text message body')
        ->setMessageBodyHtml(
            "<div>This is the <b>text/html</b> version.</div>".
            "<div>-Jie Chen</div>",
        );
    $succeeded = await $mailer->genSend();

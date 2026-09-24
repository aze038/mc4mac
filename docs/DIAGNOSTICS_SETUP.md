# Setting up FalconMail diagnostics

About 15 minutes, once. At the end, FalconMail's reports land in a Drive folder everyone at
freightmasters.llc can open, and the next release sends them.

**Everyone at freightmasters.llc can see these reports.** That is why FalconMail redacts them
before sending: no message content, subjects, addresses, names or passwords ever leave a Mac
(`docs/DIAGNOSTICS.md` explains it in plain words and lists every redaction rule).

## 1. Create the script

1. Go to [script.google.com](https://script.google.com), signed in as your **@freightmasters.llc**
   account (check the picture at the top right).
2. Click **New project**, then click "Untitled project" and name it **FalconMail Diagnostics**.
3. In Terminal, in the FalconMail repository, copy the script:

   ```sh
   pbcopy < tools/diagnostics/apps-script/Code.gs
   ```

   In the editor, select everything in `Code.gs` (⌘A) and paste (⌘V).
4. Show the manifest: click **Project Settings** (the gear on the left) and tick
   **Show "appsscript.json" manifest file in editor**. Go back to **Editor** (`< >` on the left).
5. Copy the manifest:

   ```sh
   pbcopy < tools/diagnostics/apps-script/appsscript.json
   ```

   Click `appsscript.json`, select everything and paste. Press ⌘S to save.

## 2. Run setup once

1. In the toolbar, choose **setup** from the function menu and click **Run**.
2. Click **Review permissions**, choose your @freightmasters.llc account and click **Allow**.
   The script asks for Drive and Sheets (to keep the reports), triggers (to tidy them every
   hour) and your address (to check it runs as the business account).
3. The **Execution log** opens and shows two lines you need in a moment:
   - `Ingest key (GitHub secret FALCON_DIAGNOSTICS_KEY): …`
   - `Read key (readKey in ~/.config/falconmail/diagnostics.json): …`

   Keep the tab open. If you close it, run **showKeys** to see them again.
4. The log also shows two links:
   - **This month's spreadsheet**: open it once and check that it opens on **Overview**, with
     **Issues**, **Installs** and **Events** after it.
   - **Folder**: send this link to the team. Each month's spreadsheet
     (`FalconMail Diagnostics YYYY-MM`) appears there, and the newest one is the one to use.

## 3. Deploy the web app

1. Click **Deploy** → **New deployment**. Next to "Select type", click the gear and choose
   **Web app**.
2. Description: `FalconMail diagnostics`. **Execute as: Me**. **Who has access: Anyone** (not
   "Anyone with Google account": FalconMail uploads without signing in).
3. Click **Deploy** and copy the **Web app URL**. It ends in `/exec`.

### If "Anyone" is not offered

If you only see "Anyone within freightmasters.llc", the Workspace blocks public web apps. Allow
them **for your account only**, never for the whole company:

1. In the [Admin console](https://admin.google.com), go to **Directory → Organizational units**
   and add a unit inside the one your account is in now (usually freightmasters.llc itself), for
   example **Diagnostics owner**. Then open **Directory → Users**, choose your account, **Change
   organizational unit**, and move it there. A new unit keeps every other setting of the one above
   it, so nothing else changes for you.
2. Go to **Apps → Google Workspace → Drive and Docs → Sharing settings**. **On the left, select
   Diagnostics owner first.** Under **Sharing options**, allow sharing outside freightmasters.llc
   and tick the option that lets users make files and published web content visible to anyone with
   the link. Click **Override**.
3. Wait a few minutes, then deploy again.

**Never change this with any other unit selected, freightmasters.llc least of all.** It would let
everyone in that unit share any Drive file with anyone who has the link.

"Anyone" applies only to the upload address, which accepts nothing without the ingest key. The
reports stay shared with freightmasters.llc, and nobody they are shared with can share them further.

## 4. Give the keys to GitHub and to this Mac

Nothing needs typing: each command reads what you last copied. Run these in Terminal, in the
FalconMail repository.

**Copy the Web app URL**, then:

```sh
pbpaste | tr -d '[:space:]' | gh secret set FALCON_DIAGNOSTICS_URL --repo aze038/mc4mac
```

**Copy the ingest key** from the execution log, then:

```sh
pbpaste | tr -d '[:space:]' | gh secret set FALCON_DIAGNOSTICS_KEY --repo aze038/mc4mac
```

**Save the URL and read key for the report tools.** This asks you to copy each in turn and writes
`~/.config/falconmail/diagnostics.json`, readable by you alone (it is written for zsh, the Mac's
standard shell):

```sh
(umask 077; mkdir -p ~/.config/falconmail && read -s "?Copy the Web app URL, then press Return " && U=$(pbpaste) && echo && read -s "?Copy the read key, then press Return " && K=$(pbpaste) && echo && U="$U" K="$K" python3 -c 'import json, os; print(json.dumps({"url": os.environ["U"].strip(), "readKey": os.environ["K"].strip()}))' > ~/.config/falconmail/diagnostics.json && chmod 600 ~/.config/falconmail/diagnostics.json && echo Saved.)
```

Check it works:

```sh
tools/diagnostics/fetch-reports.sh
```

It should print `No new reports.` The next FalconMail release sends reports. They appear on the
**Events** tab of this month's spreadsheet as they arrive (its filter hides the routine health and
launch reports), and on **Overview** and **Issues** within the hour.

## Good to know

- **Who can change things**: the folder is shared with the domain as **view only**. To let the
  team fill in Status, Notes and Tester name themselves, change `SHARE_PERMISSION` at the top of
  `Code.gs` to `DriveApp.Permission.EDIT`, save and run **setup** again. Editors still cannot
  share the reports with anyone else. Going back to view only works the same way, but anyone you
  added by name in Drive's **Share** dialog keeps access until you remove them there.
- **After changing `Code.gs`**: Deploy → **Manage deployments** → pencil → Version: **New version**
  → Deploy. The URL stays the same.
- **A new key**: in Project Settings → Script properties, delete `INGEST_KEY` or `READ_KEY`, run
  **setup**, and repeat step 4 for that key. A new ingest key needs a new release.
- **Old reports** go to the Drive trash 90 days after their month ends.

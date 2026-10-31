"""Replace the vendored ConPTY with another version of Microsoft's
Microsoft.Windows.Console.ConPTY package from NuGet (see README.md).

    python update.py <version>

Fetches the package, checks its id, version and license (MIT), copies
conpty.dll and OpenConsole.exe for x64 and arm64 into this folder
unmodified, checks that each carries a valid signature by Microsoft
Corporation (PowerShell's Get-AuthenticodeSignature), and prints the
SHA-256s for README.md and ../third-party.json's filePins.
"""
import hashlib
import io
import os
import subprocess
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
PACKAGE = 'Microsoft.Windows.Console.ConPTY'
FILES = {
    'x64': ['runtimes/win-x64/native/conpty.dll', 'build/native/runtimes/x64/OpenConsole.exe'],
    'arm64': ['runtimes/win-arm64/native/conpty.dll', 'build/native/runtimes/arm64/OpenConsole.exe'],
}


def signed_by_microsoft(path):
    # The path goes in the environment: -Command joins what follows it into
    # the script's text rather than passing it as $args. PSModulePath is
    # left out: run from PowerShell 7, its module folders keep Windows
    # PowerShell from loading the module Get-AuthenticodeSignature is in.
    script = ("$s = Get-AuthenticodeSignature -LiteralPath $env:CONPTY_UPDATE_FILE; "
              "($s.Status -eq 'Valid') -and ($s.SignerCertificate.Subject -like 'CN=Microsoft Corporation,*')")
    env = {k: v for k, v in os.environ.items() if k.upper() != 'PSMODULEPATH'}
    env['CONPTY_UPDATE_FILE'] = path
    r = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command', script],
                       capture_output=True, text=True, timeout=60, env=env)
    return r.stdout.strip() == 'True'


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    version = sys.argv[1]
    lower = PACKAGE.lower()
    url = f'https://api.nuget.org/v3-flatcontainer/{lower}/{version}/{lower}.{version}.nupkg'
    data = urllib.request.urlopen(url, timeout=120).read()
    print(f'{lower}.{version}.nupkg sha256 {hashlib.sha256(data).hexdigest()}')
    package = zipfile.ZipFile(io.BytesIO(data))
    nuspec = package.read(f'{PACKAGE}.nuspec').decode('utf-8')
    for want in (f'<id>{PACKAGE}</id>', f'<version>{version}</version>', '<license type="expression">MIT</license>'):
        if want not in nuspec:
            sys.exit(f'the package lacks {want}: check it by hand')
    # Each file is checked under a temporary name; the vendored ones are
    # replaced only once all four have passed.
    staged = []
    try:
        for arch, members in FILES.items():
            os.makedirs(os.path.join(HERE, arch), exist_ok=True)
            for member in members:
                path = os.path.join(HERE, arch, member.rsplit('/', 1)[1])
                body = package.read(member)
                temp = path + '.new'
                with open(temp, 'wb') as f:
                    f.write(body)
                staged.append((temp, path))
                if not signed_by_microsoft(temp):
                    sys.exit(f'{member}: not validly signed by Microsoft Corporation; nothing replaced')
                print(f'{arch}/{os.path.basename(path)} {hashlib.sha256(body).hexdigest()}')
        for temp, path in staged:
            os.replace(temp, path)
        staged = []
    finally:
        for temp, _ in staged:
            if os.path.exists(temp):
                os.remove(temp)


if __name__ == '__main__':
    main()

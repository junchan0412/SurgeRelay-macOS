#!/usr/bin/env python3
import argparse
import json
import pathlib
import re
import subprocess
import tempfile
import urllib.parse
import urllib.request

project = pathlib.Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description='Validate three source formats against six Script-Hub client outputs.')
parser.add_argument('--engine-directory', type=pathlib.Path)
parser.add_argument('--worker', type=pathlib.Path, required=True)
parser.add_argument('--output-directory', type=pathlib.Path, default=project / 'build/qa-multiclient')
args = parser.parse_args()
worker = args.worker.resolve()
outputs = args.output_directory.resolve()
outputs.mkdir(parents=True, exist_ok=True)
pin = None
if args.engine_directory:
    root = args.engine_directory.resolve()
else:
    settings = (project / 'SurgeRelay/Models/AppSettings.swift').read_text()
    module_url = re.search(r'static let defaultScriptHubModuleURL = "([^"]+)"', settings).group(1)
    parsed = urllib.parse.urlparse(module_url)
    repository_path = '/'.join(parsed.path.split('/')[:4])
    pin = parsed.path.split('/')[3]
    root = outputs / 'engine'
    root.mkdir(parents=True, exist_ok=True)
    for name in ['Rewrite-Parser.js', 'script-converter.js']:
        url = f'{parsed.scheme}://{parsed.netloc}{repository_path}/{name}'
        with urllib.request.urlopen(url, timeout=60) as response:
            (root / name).write_bytes(response.read())
fixtures = {
    'qx-rewrite': ('source.conf', '''#!name=Fixture QX
^https://example.com/ads url reject
^https://example.com/old url 302 https://example.com/new
^https://example.com/data url script-response-body https://example.com/fixture.js
hostname = example.com
'''),
    'loon-plugin': ('source.plugin', '''#!name=Fixture Loon
[Rule]
DOMAIN,example.com,DIRECT
[Rewrite]
^https://example.com/ads - reject
^https://example.com/old https://example.com/new 302
[Script]
http-response ^https://example.com/data script-path=https://example.com/fixture.js, requires-body=true, tag=Fixture
[MITM]
hostname = example.com
'''),
    'surge-module': ('source.sgmodule', '''#!name=Fixture Surge
[Rule]
DOMAIN,example.com,DIRECT
[URL Rewrite]
^https://example.com/ads - reject
^https://example.com/old https://example.com/new 302
[Script]
fixture = type=http-response, pattern=^https://example.com/data, script-path=https://example.com/fixture.js, requires-body=true
[MITM]
hostname = %APPEND% example.com
'''),
    'all-module': ('source.txt', '''#!name=Shared rules
[Rule]
DOMAIN,example.com,DIRECT
[MITM]
hostname = example.com
'''),
}
targets = {
    'Surge': ('surge-module', 'sgmodule', '[URL Rewrite]'),
    'Egern': ('surge-module', 'sgmodule', '[URL Rewrite]'),
    'Loon': ('loon-plugin', 'plugin', '[Rewrite]'),
    'Shadowrocket': ('shadowrocket-module', 'sgmodule', '[URL Rewrite]'),
    'Stash': ('stash-stoverride', 'stoverride', 'http:'),
    'Quantumult X': ('surge-module', 'sgmodule', '[rewrite_local]'),
}
qx_directory = tempfile.TemporaryDirectory(prefix='relay-qx-matrix-')
qx_root = pathlib.Path(qx_directory.name)
qx_main = qx_root / 'QXConversionMain.swift'
qx_main.write_text('''import Foundation
@main
struct QXConversionMain {
    static func main() throws {
        let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
        let result = try QuantumultXOutputConverter.convert(source)
        try Data(result.content.utf8).write(to: URL(filePath: CommandLine.arguments[2]))
        print(result.scripts.count)
    }
}
''')
qx_converter = qx_root / 'qx-convert'
subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-strict-concurrency=complete',
                '-o', str(qx_converter), str(project / 'SurgeRelay/Models/RelayError.swift'),
                str(project / 'SurgeRelay/Services/QuantumultXOutputConverter.swift'), str(qx_main)], check=True)
rows = []
for source_type, (source_name, source) in fixtures.items():
    for client, (target, extension, marker) in targets.items():
        source_url = 'https://fixtures.invalid/' + source_name
        request_url = f'http://script.hub/file/_start_/{source_url}/_end_/Fixture.{extension}?type={source_type}&target={target}'
        with tempfile.TemporaryDirectory(prefix='relay-matrix-') as folder:
            directory = pathlib.Path(folder)
            (directory / 'request.json').write_text(json.dumps({'requestURL':request_url, 'hasConverter':True, 'sourceURL':source_url}))
            (directory / 'parser.js').write_bytes((root / 'Rewrite-Parser.js').read_bytes())
            (directory / 'converter.js').write_bytes((root / 'script-converter.js').read_bytes())
            (directory / 'source.txt').write_text(source)
            subprocess.run([str(worker), str(directory)], check=True)
            response = json.loads((directory / 'response.json').read_text())
            if not response['succeeded']:
                raise RuntimeError(f'{source_type} -> {client}: {response}')
            output_file = outputs / (source_type + '-' + client.replace(' ', '-') + '.' + ('conf' if client == 'Quantumult X' else extension))
            text = (directory / 'output.txt').read_text()
            if client == 'Quantumult X':
                intermediate = outputs / (source_type + '-intermediate.sgmodule')
                intermediate.write_text(text)
                converted = subprocess.run([str(qx_converter), str(intermediate), str(output_file)], check=True, capture_output=True, text=True)
                script_count = int(converted.stdout)
                text = output_file.read_text()
            else:
                script_count = None
                output_file.write_text(text)
            if source_type == 'all-module':
                marker = 'rules:' if client == 'Stash' else '[filter_local]' if client == 'Quantumult X' else '[Rule]'
            assert marker in text, (source_type, client, marker, text)
            if source_type != 'all-module':
                assert re.search(r'example\.com/ads[^\n]*reject', text), (source_type, client, 'reject missing', text)
                assert any(all(value in line for value in ['example.com/old', 'example.com/new', '302']) for line in text.splitlines()), (source_type, client, 'redirect missing', text)
            if client == 'Stash':
                assert re.search(r'(?m)^\s+mitm:\s*\n\s+-\s+["\']?example\.com', text), (source_type, client, 'MITM hostname missing', text)
            else:
                assert '[mitm]' in text.lower() and re.search(r'(?m)^hostname\s*=\s*(?:%APPEND%\s*)?example\.com', text), (source_type, client, 'MITM hostname missing', text)
            if source_type != 'all-module':
                assert 'example.com/data' in text, (source_type, client, 'script pattern missing', text)
                assert ('example.com/fixture.js' in text or client == 'Quantumult X' and script_count == 1), (source_type, client, 'script reference missing', text)
            if source_type != 'qx-rewrite':
                assert ('DOMAIN,example.com,DIRECT' in text or 'DOMAIN,example.com,DIRECT' in text.replace(' ', '') or 'host, example.com, direct' in text), (source_type, client, 'domain rule missing', text)
            rows.append({'source':source_type, 'client':client, 'upstreamTarget':target, 'extension':output_file.suffix, 'outputBytes':len(text.encode()), 'convertedScriptAssets':script_count, 'path':str(output_file.relative_to(outputs))})
(outputs / 'matrix-result.json').write_text(json.dumps({'pin':pin,'engineDirectory':str(root),'cases':rows}, indent=2) + '\n')
print(f'Passed {len(rows)} pinned-engine conversion cases')
qx_directory.cleanup()

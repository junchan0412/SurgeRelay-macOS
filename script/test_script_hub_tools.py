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
parser = argparse.ArgumentParser(description='Validate rule and script tools against the pinned Script-Hub cores.')
parser.add_argument('--worker', type=pathlib.Path, required=True)
parser.add_argument('--engine-directory', type=pathlib.Path)
parser.add_argument('--output-directory', type=pathlib.Path, default=project / 'build/qa-tools')
args = parser.parse_args()
worker = args.worker.resolve()
outputs = args.output_directory.resolve()
outputs.mkdir(parents=True, exist_ok=True)
settings = (project / 'SurgeRelay/Models/AppSettings.swift').read_text()
module_url = re.search(r'static let defaultScriptHubModuleURL = "([^"]+)"', settings).group(1)
parsed = urllib.parse.urlparse(module_url)
configured_pin = parsed.path.split('/')[3]
pin = None
if args.engine_directory:
    engine = args.engine_directory.resolve()
else:
    pin = configured_pin
    repository_path = '/'.join(parsed.path.split('/')[:4])
    engine = outputs / 'engine'
    engine.mkdir(parents=True, exist_ok=True)
    for name in ['rule-parser.js', 'script-converter.js']:
        url = f'{parsed.scheme}://{parsed.netloc}{repository_path}/{name}'
        with urllib.request.urlopen(url, timeout=60) as response:
            (engine / name).write_bytes(response.read())
rule_parser = (engine / 'rule-parser.js').read_bytes()
script_converter = (engine / 'script-converter.js').read_bytes()
fixtures_directory = outputs / 'fixtures'
fixtures_directory.mkdir(parents=True, exist_ok=True)

rule_fixtures = {
    'qx-rules': ('''# Quantumult X filter_remote
host, qx.example.com, reject
host-suffix, ads.example.com, reject
ip6-cidr, 2001:db8::/32, reject, no-resolve
''', ['DOMAIN,qx.example.com', 'DOMAIN-SUFFIX,ads.example.com', 'IP-CIDR6,2001:db8::/32,no-resolve']),
    'surge-loon-rules': ('''# Surge / Loon rule-set
DOMAIN,surge.example.com
DOMAIN-SUFFIX,ads.example.com
IP-CIDR,192.0.2.0/24,no-resolve
IP-CIDR6,2001:db8::/32,no-resolve
''', ['DOMAIN,surge.example.com', 'DOMAIN-SUFFIX,ads.example.com',
      'IP-CIDR,192.0.2.0/24,no-resolve', 'IP-CIDR6,2001:db8::/32,no-resolve']),
    'clash-payload': ('''payload:
  - 'DOMAIN,clash.example.com'
  - 'DOMAIN-SUFFIX,ads.example.com'
  - 'IP-CIDR,198.51.100.0/24,no-resolve'
  - 'IP-CIDR6,2001:db8::/32,no-resolve'
''', ['DOMAIN,clash.example.com', 'DOMAIN-SUFFIX,ads.example.com',
      'IP-CIDR,198.51.100.0/24,no-resolve', 'IP-CIDR6,2001:db8::/32,no-resolve']),
    'plain-domain-cidr': ('''plain.example.com
.suffix.example.com
203.0.113.0/24
2001:db8::/32
''', ['DOMAIN,plain.example.com', 'DOMAIN-SUFFIX,suffix.example.com',
      'IP-CIDR,203.0.113.0/24', 'IP-CIDR6,2001:db8::/32']),
}
rule_targets = {
    'Surge': ('surge-rule-set', 'list'),
    'Egern': ('surge-rule-set', 'list'),
    'Loon': ('loon-rule-set', 'list'),
    'Shadowrocket': ('shadowrocket-rule-set', 'list'),
    'Stash': ('stash-rule-set', 'yaml'),
    'Quantumult X': ('surge-rule-set', 'list'),
}
script_targets = ['Surge', 'Egern', 'Loon', 'Shadowrocket', 'Stash']
qx_script = '''const marker = "fixture-qx-script ❌";
const stored = $prefs.valueForKey("fixture-key");
$notify("fixture", "", marker);
$task.fetch({url: "https://fixtures.invalid/offline-api", method: "PUT"}).then(response => {
  $done({body: JSON.stringify({marker, stored, status: response.statusCode, body: response.body})});
});
'''
surge_script = '''const marker = "fixture-surge-script ❌";
const stored = $persistentStore.read("fixture-key");
$notification.post("fixture", "", marker);
$httpClient.get({url: "https://fixtures.invalid/offline-api"}, (error, response, body) => {
  $done({body: JSON.stringify({marker, stored, status: response.status, body})});
});
'''
generic_script = '''const marker = "fixture-generic-script ❌";
const stored = $persistentStore.read("fixture-key");
$done({body: JSON.stringify({marker, stored})});
'''
for name, (source, _) in rule_fixtures.items():
    (fixtures_directory / (name + '.txt')).write_bytes(source.encode())
for name, source in [('qx-script', qx_script), ('surge-script', surge_script), ('generic-script', generic_script)]:
    (fixtures_directory / (name + '.js')).write_bytes(source.encode())

temporary = tempfile.TemporaryDirectory(prefix='relay-tools-matrix-')
temporary_root = pathlib.Path(temporary.name)
qx_main = temporary_root / 'QXToolsMain.swift'
qx_main.write_text('''import Foundation
@main
struct QXToolsMain {
    static func main() throws {
        let source = try String(contentsOfFile: CommandLine.arguments[2], encoding: .utf8)
        let result: String
        switch CommandLine.arguments[1] {
        case "rules": result = try QuantumultXOutputConverter.ruleSet(source, policy: "REJECT")
        case "normalize-rules": result = QuantumultXOutputConverter.normalizingRuleSource(source)
        case "qx-to-surge-script": result = QuantumultXOutputConverter.adaptingConvertedQuantumultXScript(source)
        default: result = try QuantumultXOutputConverter.adaptingScript(source, argument: nil)
        }
        try Data(result.utf8).write(to: URL(filePath: CommandLine.arguments[3]))
    }
}
''')
qx_converter = temporary_root / 'qx-tools'
subprocess.run(['xcrun', 'swiftc', '-O', '-swift-version', '6', '-strict-concurrency=complete',
                '-o', str(qx_converter), str(project / 'SurgeRelay/Models/RelayError.swift'),
                str(project / 'SurgeRelay/Services/QuantumultXOutputConverter.swift'), str(qx_main)], check=True)
normalized_rule_sources = {}
for name in rule_fixtures:
    normalized_file = fixtures_directory / (name + '.normalized.txt')
    subprocess.run([str(qx_converter), 'normalize-rules', str(fixtures_directory / (name + '.txt')), str(normalized_file)],
                   check=True, capture_output=True, text=True)
    normalized_rule_sources[name] = normalized_file.read_text()
node_runner = temporary_root / 'fixture-runner.cjs'
node_runner.write_text('''const fs = require('node:fs');
const vm = require('node:vm');
const done = [];
const requests = [];
const notifications = [];
const context = {
  $request: {url: 'https://fixtures.invalid/request', method: 'GET', headers: {}},
  $done: value => done.push(value),
  $persistentStore: {read: key => key === 'fixture-key' ? 'fixture-value' : null, write: () => true},
  $notification: {post: (...values) => notifications.push(values)},
  $httpClient: Object.fromEntries(['get', 'post', 'put', 'delete'].map(method => [method, (request, callback) => {
    requests.push({url: request.url, method: method.toUpperCase()});
    callback(null, {status: 200, headers: {}}, 'fixture-http-body');
  }])),
  $prefs: {valueForKey: key => key === 'fixture-key' ? 'fixture-value' : null, setValueForKey: () => true},
  $notify: (...values) => notifications.push(values),
  $task: {fetch: request => {
    requests.push({url: request.url, method: request.method || 'GET'});
    return Promise.resolve({statusCode: 200, headers: {}, body: 'fixture-http-body'});
  }},
  console: {log: () => {}, warn: () => {}, error: () => {}}
};
(async () => {
  vm.runInNewContext(fs.readFileSync(process.argv[2], 'utf8'), context, {timeout: 1000});
  await Promise.resolve();
  await Promise.resolve();
  if (done.length !== 1) throw new Error('Expected one $done call, got ' + done.length);
  const result = done[0].response || done[0];
  process.stdout.write(JSON.stringify({result: JSON.parse(result.body), requests, notifications}));
})().catch(error => { console.error(error); process.exitCode = 1; });
''')


def run_worker(case_name, source, core, request_url, source_url, expect_failure=False):
    with tempfile.TemporaryDirectory(prefix='relay-tools-worker-') as folder:
        directory = pathlib.Path(folder)
        request = {'requestURL': request_url, 'hasConverter': False, 'sourceURL': source_url}
        (directory / 'request.json').write_text(json.dumps(request))
        (directory / 'parser.js').write_bytes(core)
        (directory / 'source.txt').write_bytes(source.encode())
        subprocess.run([str(worker), str(directory)], check=True, capture_output=True, text=True)
        response = json.loads((directory / 'response.json').read_text())
        (outputs / (case_name + '.response.json')).write_text(json.dumps(response, indent=2) + '\n')
        if expect_failure:
            assert not response['succeeded'], ('helper accepted HTTP error', response)
            assert 'HTTP 500' in response['error'] and 'fixture-core-error' in response['error'], response
            assert not (directory / 'output.txt').exists(), 'helper wrote an error response as output'
            return response
        if not response['succeeded']:
            raise RuntimeError(response['error'])
        return (directory / 'output.txt').read_text()


def actual_rules(content, stash=False):
    values = [line.strip() for line in content.splitlines() if line.strip() and not line.lstrip().startswith('#')]
    if stash:
        assert values[0] == 'payload:', ('missing Stash payload', values)
        assert all(value.startswith('- ') for value in values[1:]), ('invalid Stash payload item', values)
        values = [value[2:].strip().strip('\"\'') for value in values[1:]]
    return [','.join(part.strip() for part in value.split(',')) for value in values]


def check_script(path, marker, has_http, row, method='GET'):
    row['syntaxValid'] = False
    subprocess.run(['node', '--check', str(path)], check=True, capture_output=True, text=True)
    row['syntaxValid'] = True
    result = subprocess.run(['node', str(node_runner), str(path)], check=True, capture_output=True, text=True)
    execution = json.loads(result.stdout)
    row['execution'] = execution
    expected = {'marker': marker, 'stored': 'fixture-value'}
    if has_http:
        expected.update(status=200, body='fixture-http-body')
        assert execution['requests'] == [{'url': 'https://fixtures.invalid/offline-api', 'method': method}], execution
        assert len(execution['notifications']) == 1 and execution['notifications'][0][2] == marker, execution
    else:
        assert execution['requests'] == [], execution
    assert execution['result'] == expected, (execution, expected)
    return execution


rows = []
for source_name, (source, expected) in rule_fixtures.items():
    for client, (target, extension) in rule_targets.items():
        case_name = source_name + '-' + client.replace(' ', '-')
        source_url = 'https://fixtures.invalid/' + source_name + '.list'
        request_url = f'http://script.hub/file/_start_/{source_url}/_end_/Rule.list?type=rule-set&target={target}'
        output_file = outputs / (case_name + '.' + extension)
        row = {'tool': 'rules', 'source': source_name, 'client': client, 'upstreamTarget': target,
               'requestURL': request_url, 'policy': 'REJECT' if client == 'Quantumult X' else None,
               'inputNormalizer': 'QuantumultXOutputConverter.normalizingRuleSource',
               'inputPath': str((fixtures_directory / (source_name + '.normalized.txt')).relative_to(outputs)),
               'path': str(output_file.relative_to(outputs))}
        rows.append(row)
        try:
            content = run_worker(case_name, normalized_rule_sources[source_name], rule_parser, request_url, source_url)
            output_file.write_bytes(content.encode())
            if client == 'Quantumult X':
                intermediate = outputs / (case_name + '.surge.list')
                intermediate.write_bytes(content.encode())
                subprocess.run([str(qx_converter), 'rules', str(intermediate), str(output_file)],
                               check=True, capture_output=True, text=True)
                content = output_file.read_text()
                qx_types = {'DOMAIN': 'host', 'DOMAIN-SUFFIX': 'host-suffix', 'IP-CIDR': 'ip-cidr', 'IP-CIDR6': 'ip6-cidr'}
                expected_output = [qx_types[value.split(',')[0]] + ',' + value.split(',')[1] + ',reject' for value in expected]
                assert '[' not in content and not any(line.startswith('#') for line in content.splitlines()), content
            else:
                expected_output = expected
            rules = actual_rules(content, stash=client == 'Stash')
            row.update(rules=rules, outputBytes=len(content.encode()))
            assert rules == expected_output, (rules, expected_output)
            row['passed'] = True
        except (AssertionError, RuntimeError, subprocess.CalledProcessError) as error:
            detail = error.stderr or str(error) if isinstance(error, subprocess.CalledProcessError) else str(error)
            row.update(passed=False, error=detail)

for source_name, source, source_type, compatibility, marker, has_http in [
    ('qx-script', qx_script, 'qx-script', False, 'fixture-qx-script ❌', True),
    ('generic-script', generic_script, 'surge-script', True, 'fixture-generic-script ❌', False),
]:
    for client in script_targets:
        case_name = source_name + '-' + client.replace(' ', '-')
        source_url = 'https://fixtures.invalid/' + source_name + '.js'
        query = urllib.parse.urlencode({'type': source_type, 'target': 'surge-script',
                                      **({'compatibilityOnly': 'true'} if compatibility else {})})
        request_url = f'http://script.hub/convert/_start_/{source_url}/_end_/Tool.js?{query}'
        output_file = outputs / (case_name + '.js')
        row = {'tool': 'scripts', 'source': source_name, 'client': client, 'upstreamTarget': 'surge-script',
               'requestURL': request_url, 'compatibilityOnly': compatibility, 'path': str(output_file.relative_to(outputs))}
        rows.append(row)
        try:
            content = run_worker(case_name, source, script_converter, request_url, source_url)
            if source_type == 'qx-script':
                intermediate = outputs / (case_name + '.pinned.js')
                intermediate.write_bytes(content.encode())
                subprocess.run([str(qx_converter), 'qx-to-surge-script', str(intermediate), str(output_file)],
                               check=True, capture_output=True, text=True)
                content = output_file.read_text()
                row.update(localConverter='QuantumultXOutputConverter.adaptingConvertedQuantumultXScript',
                           intermediatePath=str(intermediate.relative_to(outputs)))
            else:
                output_file.write_bytes(content.encode())
            assert marker in content and '_scriptSonverterCompatibilityDone' in content, 'script body or compatibility wrapper missing'
            execution = check_script(output_file, marker, has_http, row, method='PUT' if source_name == 'qx-script' else 'GET')
            row.update(passed=True, syntaxValid=True, execution=execution, outputBytes=len(content.encode()))
        except (AssertionError, RuntimeError, subprocess.CalledProcessError) as error:
            detail = error.stderr or str(error) if isinstance(error, subprocess.CalledProcessError) else str(error)
            row.update(passed=False, error=detail)

for client in ['Surge', 'Loon']:
    case_name = client.lower() + '-script-Quantumult-X'
    output_file = outputs / (case_name + '.js')
    row = {'tool': 'scripts', 'source': client.lower() + '-script', 'client': 'Quantumult X',
           'localConverter': 'QuantumultXOutputConverter.adaptingScript', 'path': str(output_file.relative_to(outputs))}
    rows.append(row)
    try:
        subprocess.run([str(qx_converter), 'script', str(fixtures_directory / 'surge-script.js'), str(output_file)],
                       check=True, capture_output=True, text=True)
        execution = check_script(output_file, 'fixture-surge-script ❌', True, row)
        row.update(passed=True, syntaxValid=True, execution=execution, outputBytes=output_file.stat().st_size)
    except (AssertionError, subprocess.CalledProcessError) as error:
        detail = error.stderr or str(error) if isinstance(error, subprocess.CalledProcessError) else str(error)
        row.update(passed=False, error=detail)

for tool, core, route, source, source_type, target in [
    ('rules', rule_parser, 'file', rule_fixtures['surge-loon-rules'][0], 'rule-set', 'surge-rule-set'),
    ('scripts', script_converter, 'convert', generic_script, 'surge-script', 'surge-script'),
]:
    case_name = tool + '-core-http-error'
    source_url = 'https://fixtures.invalid/core-error.txt'
    query = urllib.parse.urlencode({'type': source_type, 'target': target,
                                   'evalScriptori': "throw new Error('fixture-core-error')"}, quote_via=urllib.parse.quote)
    request_url = f'http://script.hub/{route}/_start_/{source_url}/_end_/Tool.js?{query}'
    row = {'tool': tool, 'source': 'core-http-error', 'client': 'Surge', 'requestURL': request_url,
           'expected': 'HTTP 500 rejected'}
    rows.append(row)
    try:
        response = run_worker(case_name, source, core, request_url, source_url, expect_failure=True)
        row.update(passed=True, helperError=response['error'])
    except (AssertionError, RuntimeError, subprocess.CalledProcessError) as error:
        detail = error.stderr or str(error) if isinstance(error, subprocess.CalledProcessError) else str(error)
        row.update(passed=False, error=detail)

result = {'pin': pin, 'configuredPin': configured_pin, 'moduleURL': module_url,
          'engineDirectory': str(engine), 'worker': str(worker), 'cases': rows}
(outputs / 'matrix-result.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
temporary.cleanup()
failed = [row for row in rows if not row['passed']]
for row in failed:
    print(f"Failed {row['tool']} {row['source']} -> {row['client']}: {row['error']}")
print(f'Passed {len(rows) - len(failed)}/{len(rows)} rule and script conversion cases')
raise SystemExit(1 if failed else 0)

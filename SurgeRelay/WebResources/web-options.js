(function installSurgeRelayWebOptions(global) {
  function textField(key, label, prompt = '', help = '', multiline = false) {
    return { type: multiline ? 'textarea' : 'text', key, label, prompt, help };
  }

  function toggleField(key, label) {
    return { type: 'toggle', key, label };
  }

  function headingField(label) {
    return { type: 'heading', label };
  }

  function pairedGroup(id, title, firstKey, firstLabel, firstPrompt, secondKey, secondLabel, secondPrompt) {
    return {
      id,
      title,
      description: '多项使用 + 分隔；目标和值需要一一对应。',
      fields: [
        textField(firstKey, firstLabel, firstPrompt),
        textField(secondKey, secondLabel, secondPrompt)
      ]
    };
  }

  const scriptHubDefaults = {
    scriptConversionKeywords: '', convertAllScripts: false,
    responseScriptConversionKeywords: '', convertAllResponseScripts: false,
    compatibilityOnly: false, prependScript: '', scriptEvalOriginal: '',
    scriptEvalConverted: '', scriptEvalOriginalURL: '', scriptEvalConvertedURL: '',
    includeKeywords: '', excludeKeywords: '', syncMITMToForceHTTP: false,
    removeCommentedRewrites: true, keepMapLocalHeaders: false, useJSDelivr: false,
    policy: '', mitmAdd: '', mitmRemove: '', mitmRemoveRegex: '',
    scriptNameTargets: '', scriptNames: '', timeoutTargets: '', timeoutValues: '',
    engineTargets: '', engineValues: '', cronTargets: '', cronExpressions: '',
    argumentTargets: '', argumentValues: '', noResolve: false, sniKeywords: '',
    preMatchingKeywords: '', enableJQ: true, requestHeaders: '', evalOriginal: '',
    evalConverted: '', evalOriginalURL: '', evalConvertedURL: ''
  };

  const advancedGroups = [
    {
      id: 'script-conversion', title: '启用脚本转换',
      description: '仅在脚本使用了来源 App 独有 API 时启用。启用后，App 会预先转换脚本并将辅助资源发布到 GitHub。',
      fields: [
        textField('scriptConversionKeywords', '脚本转换 1 关键词', '例如：response-body.js+request.js', '多关键词使用 + 分隔。'),
        toggleField('convertAllScripts', '脚本转换 1：全部转换'),
        textField('responseScriptConversionKeywords', '脚本转换 2 关键词', '例如：response.js+parser.js', '转换 2 会为 $done(body) 包装 response。'),
        toggleField('convertAllResponseScripts', '脚本转换 2：全部转换并包装 response'),
        toggleField('compatibilityOnly', '仅进行兼容性转换'),
        textField('prependScript', '在脚本开头添加代码', "例如：console.log(new Date().toLocaleString('zh'))", '代码会添加到被转换脚本的开头。', true),
        headingField('脚本转换高级处理'),
        textField('scriptEvalOriginal', '处理脚本原始内容（代码）', "例如：body = body.replace(/old/g, 'new')", '', true),
        textField('scriptEvalConverted', '处理脚本转换后内容（代码）', "例如：body = body.replace(/old/g, 'new')", '', true),
        textField('scriptEvalOriginalURL', '处理脚本原始内容（代码 URL）', 'https://example.com/process-original.js'),
        textField('scriptEvalConvertedURL', '处理脚本转换后内容（代码 URL）', 'https://example.com/process-converted.js')
      ]
    },
    {
      id: 'rewrites', title: '重写相关', fields: [
        textField('includeKeywords', '保留重写关键词', '例如：login+account', '匹配的已注释重写会被启用。'),
        textField('excludeKeywords', '排除重写关键词', '例如：tracking+analytics', '匹配的重写会被注释。'),
        toggleField('syncMITMToForceHTTP', '将 MitM 主机名同步到 force-http-engine-hosts'),
        toggleField('removeCommentedRewrites', '剔除被注释的重写'),
        toggleField('keepMapLocalHeaders', '保留 Map Local / echo-response 的 Header'),
        toggleField('useJSDelivr', '将 GitHub 脚本地址转换为 jsDelivr')
      ]
    },
    {
      id: 'policy',
      title: '指定策略',
      description: '为未指定策略或使用非 Surge 内置策略的规则指定一个替代策略。',
      fields: [textField('policy', '策略', '例如：DIRECT、REJECT 或你的策略组名称')]
    },
    {
      id: 'mitm', title: '修改 MitM 主机名', fields: [
        textField('mitmAdd', '添加主机名', '例如：api.example.com, *.example.com', '多个主机名使用英文逗号分隔。'),
        textField('mitmRemove', '删除主机名', '例如：ads.example.com, track.example.com'),
        textField('mitmRemoveRegex', '按正则删除主机名', '例如：(^|\\.)ads\\.example\\.com$')
      ]
    },
    pairedGroup('script-name', '修改脚本名', 'scriptNameTargets', '关键词锁定脚本 (njsnametarget)', '例如：checkin+account', 'scriptNames', '新的脚本名 (njsname)', '例如：签到任务+账户任务'),
    pairedGroup('timeout', '修改脚本超时', 'timeoutTargets', '关键词锁定脚本 (timeoutt)', '例如：checkin+account', 'timeoutValues', '超时值 (timeoutv)', '例如：10+30'),
    pairedGroup('engine', '修改脚本引擎（Surge）', 'engineTargets', '关键词锁定脚本 (enginet)', '例如：legacy-script', 'engineValues', '引擎 (enginev)', '例如：webview'),
    pairedGroup('cron', '修改定时任务', 'cronTargets', '关键词锁定任务 (cron)', '例如：daily-checkin', 'cronExpressions', 'Cron 表达式 (cronexp)', '例如：0.0.8.*.*.*'),
    pairedGroup('arguments', '修改参数', 'argumentTargets', '关键词锁定脚本 (arg)', '例如：account-script', 'argumentValues', 'Argument 新值 (argv)', '例如：key=value'),
    {
      id: 'rules', title: '规则与请求', fields: [
        toggleField('noResolve', 'IP 规则开启 no-resolve'),
        textField('sniKeywords', 'SNI 扩展匹配关键词', '例如：DOMAIN-SUFFIX+RULE-SET'),
        textField('preMatchingKeywords', 'pre-matching 关键词', '例如：REJECT+tracking'),
        toggleField('enableJQ', '开启 JQ'),
        textField('requestHeaders', '自定义请求 Header', 'User-Agent:script-hub/1.0.0\nAuthorization:token xxx', '每行一个 Header，使用英文冒号分隔名称和值。', true)
      ]
    },
    {
      id: 'content-processing', title: '高级内容处理', fields: [
        textField('evalOriginal', '处理原始内容（代码）', "例如：body = body.replace(/old/g, 'new')", '', true),
        textField('evalConverted', '处理转换后内容（代码）', "例如：body = body.replace(/old/g, 'new')", '', true),
        textField('evalOriginalURL', '处理原始内容（代码 URL）', 'https://example.com/process-original.js'),
        textField('evalConvertedURL', '处理转换后内容（代码 URL）', 'https://example.com/process-converted.js')
      ]
    }
  ];

  global.SurgeRelayWebOptions = {
    scriptHubDefaults,
    advancedGroups
  };
})(globalThis);

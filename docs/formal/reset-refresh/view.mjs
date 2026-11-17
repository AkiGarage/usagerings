export const title = 'リセット専用取得';
export const state = v => v.stopped ? '停止' : v.running > 0 ? '取得中' : v.timers.length ? '予約あり' : v.consumed.length ? '確認済み' : '予約なし';
export const step = action => ({ Learn: '新しい期限', Tick: '時刻進行', Poll: '通常取得', Busy: '期限到来・取得完了待ち', Complete: '取得完了と再計画', Fire: 'リセット確認', Stop: '監視停止' }[action] ?? null);

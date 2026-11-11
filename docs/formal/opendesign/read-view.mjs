export const title = 'OpenDesignの読み取り';
export const state = v => ({idle:'待機', credential:'公式ログインを読む', directory:'個人ワークスペースを読む', funding:'利用枠を読む', hidden:'非表示・通信なし', login:'ログイン案内', failure:'取得失敗', shown:'検証した残量を表示'}[v.phase]);
export const step = a => ({Start:'更新開始', Credential:'認証情報を確認', Directory:'ワークスペース応答', Funding:'利用枠応答', Done:'完了'}[a] ?? a);

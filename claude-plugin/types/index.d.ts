export type SessionRow = {
  id: string
  title: string
  cwd: string
  isRunning: boolean
  lastActivityAt: string
  link?: string
}

declare module 'claude-code' {
  interface PluginState {
    'agent-dock': {
      sessions: Shaped<SessionRow[]>
      expanded: Shaped<string[]>
      // Sessions that stopped while not on screen and have not been looked at since.
      unread: Shaped<string[]>
      // How far back idle sessions are listed: '6h', '24h', '7d' or 'all'.
      range: Shaped<string>
      error: Shaped<string>
    }
  }
}

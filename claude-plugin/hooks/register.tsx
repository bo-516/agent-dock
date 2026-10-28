import { atom, read, update } from 'claude-code'
import type { EngineInterface, Register } from 'claude-code'

import type { SessionRow } from '../types'

const PANE = 'agent-dock'
const TITLE = '会话'
// `$.store` key, kept across sessions: false once the person closed the pane.
const PANE_OPEN = 'paneOpen'
// How many sessions each project shows before "see more".
const SHOWN = 5
const REFRESH_MS = 4000
// Idle sessions older than the chosen range are left out, and so is a project with none left.
const HOUR = 60 * 60 * 1000
const RANGES: ReadonlyArray<{ key: string; ms: number; empty: string }> = [
  { key: '6h', ms: 6 * HOUR, empty: '6 小时内没有活动的会话' },
  { key: '24h', ms: 24 * HOUR, empty: '24 小时内没有活动的会话' },
  { key: '7d', ms: 7 * 24 * HOUR, empty: '7 天内没有活动的会话' },
  { key: 'all', ms: Number.POSITIVE_INFINITY, empty: '没有会话' },
]
// Markdown only draws https links; the plugin answers presses on these itself.
const PRESS_BASE = 'https://agent-dock.invalid/'

// Change a tag when that value's fields change: it declines what an earlier
// version stored, which outlives a reload.
const sessions = atom({ plugin: 'agent-dock', key: 'sessions' } as const, [], {
  shape: 'sessions-1',
})
const expanded = atom({ plugin: 'agent-dock', key: 'expanded' } as const, [], {
  shape: 'expanded-1',
})
const error = atom({ plugin: 'agent-dock', key: 'error' } as const, '', {
  shape: 'error-1',
})
const unread = atom({ plugin: 'agent-dock', key: 'unread' } as const, [], {
  shape: 'unread-1',
})
const range = atom({ plugin: 'agent-dock', key: 'range' } as const, '6h', {
  shape: 'range-1',
})

type Status = 'running' | 'unread' | 'seen'

const IDLE_DOT = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 12 12" width="12" height="12">
<circle cx="6" cy="6" r="2.5" fill="#9B9B9B"/></svg>`

const UNREAD_DOT = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 12 12" width="12" height="12">
<circle cx="6" cy="6" r="3.5" fill="#3B82F6"/></svg>`

const SPINNER = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 12 12" width="12" height="12">
<circle cx="6" cy="6" r="4.5" fill="none" stroke="#D97757" stroke-opacity="0.25" stroke-width="2"/>
<path d="M6 1.5 a4.5 4.5 0 0 1 4.5 4.5" fill="none" stroke="#D97757" stroke-width="2" stroke-linecap="round">
<animateTransform attributeName="transform" type="rotate" from="0 6 6" to="360 6 6" dur="0.8s" repeatCount="indefinite"/>
</path></svg>`

type Layout = {
  main_window?: { tab?: string; panes?: Array<{ session_id?: string }> }
  popout_windows?: { sessions?: Array<string | { session_id?: string }> }
}

type Listed = {
  sessionId: string
  title?: string
  cwd?: string
  isRunning?: boolean
  lastActivityAt?: string
  link?: string
  // Set on a session another session started: a /btw question, a fork, a task card.
  startedBy?: string
  parentSessionId?: string
}

// Left out of the pane and the dock: side questions (/btw), sessions another
// session started, and sessions nobody has written in yet (still untitled).
function isCounted(one: Listed) {
  if (one.startedBy || one.parentSessionId) return false
  const title = (one.title ?? '').trim()
  if (/^btw\b/i.test(title)) return false

  return title !== '' && !/^(untitled|new)( session| chat)?$/i.test(title)
}

async function callText($: EngineInterface, server: string, tool: string, args: Record<string, unknown>) {
  const result = await $.mcp.call(server, tool, args)
  const text = result.content.flatMap(block => (block.type === 'text' ? [block.text] : [])).join('')
  if (result.isError) throw new Error(text || `${tool} failed`)

  return text
}

// The sessions the person has in front of them: the Code tab's panes and pop-out windows.
async function onScreen($: EngineInterface) {
  try {
    const layout = JSON.parse(await callText($, 'ccd_window', 'get_window_layout', {})) as Layout
    const ids = new Set<string>()
    if (layout.main_window?.tab === 'code') {
      for (const pane of layout.main_window.panes ?? []) if (pane.session_id) ids.add(pane.session_id)
    }
    for (const one of layout.popout_windows?.sessions ?? []) {
      const id = typeof one === 'string' ? one : one.session_id
      if (id) ids.add(id)
    }

    return ids
  } catch {
    return new Set<string>()
  }
}

// The shared state every session's pane and the menu bar app (macos/ in this repository) read.
// One session at a time writes it: the one named `writer`, or any session
// once the writer has gone quiet. Unread marks live in the file, so they
// survive a change of writer.
type Exported = {
  writer: string
  updatedAt: string
  sessions: Array<{
    id: string
    title: string
    cwd: string
    project: string
    projectKey: string
    status: Status
    lastActivityAt: string
    link: string
  }>
}

// A writer that has not written for this long is taken over.
const STALE_MS = 3 * REFRESH_MS

async function boardFile($: EngineInterface, name: string) {
  const home = await $.env.get('HOME')

  return home ? `${home}/.claude/agent-dock/${name}` : undefined
}

async function readExported($: EngineInterface, path: string) {
  try {
    return JSON.parse(await $.fs.read(path)) as Exported
  } catch {
    return undefined
  }
}

function toRow(one: Listed): SessionRow {
  return {
    id: one.sessionId,
    title: one.title || 'Untitled',
    cwd: one.cwd ?? '',
    isRunning: one.isRunning === true,
    // To the minute: a running session's activity then redraws the pane once a
    // minute rather than every poll, which kept moving the pane under the pointer.
    lastActivityAt: toMinute(one.lastActivityAt),
    link: one.link,
  }
}

// list_sessions leaves out the session that asks, so the writer adds itself.
async function listSessions($: EngineInterface) {
  const listed = JSON.parse(await callText($, 'ccd_session_mgmt', 'list_sessions', { limit: 100 })) as Listed[]
  try {
    listed.push(JSON.parse(await callText($, 'ccd_session_mgmt', 'get_session', { session_id: 'self' })) as Listed)
  } catch {
    // Listed without this session.
  }

  return listed
    .filter(one => one.sessionId && isCounted(one))
    .map(toRow)
    .sort((a, b) => Date.parse(b.lastActivityAt || '0') - Date.parse(a.lastActivityAt || '0'))
}

async function refresh($: EngineInterface) {
  try {
    const path = await boardFile($, 'state.json')
    const me = await $.session.id()
    const now = await $.clock.now()
    const last = path ? await readExported($, path) : undefined
    const isWriter = !last || last.writer === me || now - Date.parse(last.updatedAt) > STALE_MS

    let rows: SessionRow[]
    let marked: string[]
    if (isWriter || !last) {
      rows = await listSessions($)
      const visible = await onScreen($)

      // A session that stopped since the last look is unread until it is on screen.
      const wasRunning = new Set(last?.sessions.filter(s => s.status === 'running').map(s => s.id))
      const marks = last?.sessions.filter(s => s.status === 'unread').map(s => s.id) ?? []
      const idle = new Set(rows.filter(s => !s.isRunning).map(s => s.id))
      const stopped = [...idle].filter(id => wasRunning.has(id))
      marked = [...new Set([...marks, ...stopped])].filter(id => idle.has(id) && !visible.has(id))
      if (path) await writeExported($, path, me, now, rows, new Set(marked))
    } else {
      rows = last.sessions.map(s => ({
        id: s.id,
        title: s.title,
        cwd: s.cwd,
        isRunning: s.status === 'running',
        lastActivityAt: s.lastActivityAt,
        link: s.link || undefined,
      }))
      marked = last.sessions.filter(s => s.status === 'unread').map(s => s.id)
    }

    if (JSON.stringify(await read($, unread)) !== JSON.stringify(marked)) await update($, unread, () => marked)
    if (JSON.stringify(await read($, sessions)) !== JSON.stringify(rows)) await update($, sessions, () => rows)
    if ((await read($, error)) !== '') await update($, error, () => '')
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err)
    await update($, error, () => message)
  }
}

async function writeExported(
  $: EngineInterface,
  path: string,
  writer: string,
  now: number,
  rows: SessionRow[],
  marks: Set<string>,
) {
  const data: Exported = {
    writer,
    updatedAt: new Date(now).toISOString(),
    // Every session: each pane and the menu bar app apply their own range.
    sessions: rows.map(s => ({
      id: s.id,
      title: s.title,
      cwd: s.cwd,
      project: projectOf(s.cwd).name,
      projectKey: projectOf(s.cwd).key,
      status: s.isRunning ? 'running' : marks.has(s.id) ? 'unread' : 'seen',
      lastActivityAt: s.lastActivityAt,
      link: s.link ?? '',
    })),
  }
  await $.fs.write(path, JSON.stringify(data))
}

// The plan's usage windows are the account's, so whichever session got the
// latest reading writes them, with when it got it.
async function writeUsage($: EngineInterface, windows: readonly { kind: string; percentUsed: number; resetsAt?: string }[]) {
  try {
    const path = await boardFile($, 'usage.json')
    if (!path || windows.length === 0) return
    const now = await $.clock.now()
    const data = {
      at: new Date(now).toISOString(),
      windows: windows.map(one => ({ kind: one.kind, percentUsed: one.percentUsed, resetsAt: one.resetsAt ?? '' })),
    }
    await $.fs.write(path, JSON.stringify(data))
  } catch {
    // The menu bar app keeps the last reading it has.
  }
}

async function openSession($: EngineInterface, s: SessionRow) {
  if (!s.link?.startsWith('claude://')) return
  await update($, unread, ids => ids.filter(id => id !== s.id))
  await $.process.run(['open', s.link])
}

function toMinute(iso: string | undefined) {
  const ms = Date.parse(iso ?? '')
  if (!Number.isFinite(ms)) return ''

  return new Date(Math.floor(ms / 60000) * 60000).toISOString()
}

function projectOf(cwd: string) {
  if (cwd === '' || cwd.includes('/scratch-workspaces/')) return { key: 'scratch', name: 'No Project' }
  const name = cwd.split('/').filter(Boolean).pop() ?? cwd

  return { key: cwd, name: name || 'No Project' }
}

// "35m ago", "1h 20m ago" (or "3h ago" on the hour), "2d ago" from a day on.
function ago(iso: string, now: number) {
  const minutes = Math.floor((now - Date.parse(iso)) / 60000)
  if (!Number.isFinite(minutes) || minutes < 1) return 'just now'
  if (minutes < 60) return `${minutes}m ago`
  const hours = Math.floor(minutes / 60)
  if (hours < 24) return minutes % 60 === 0 ? `${hours}h ago` : `${hours}h ${minutes % 60}m ago`

  return `${Math.floor(hours / 24)}d ago`
}

function escapeMarkdown(text: string) {
  return text.replace(/[\\`*_[\]<>#|~]/g, ch => `\\${ch}`)
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.command.register({
      name: 'sessions',
      description: 'Show or hide the pane of all Code sessions by project',
    })
    void refresh($)
    $.clock.every(REFRESH_MS, () => refresh($))
    // Open or closed as the person last left it, in any session; open at first.
    if ((await $.store.get(PANE_OPEN)) !== false) void $.ui.open({ id: PANE, title: TITLE })

    return next(e)
  })

  on('command.run', { command: 'sessions' }, async $ => {
    const isUp = (await $.ui.panes()).some(pane => pane.id === PANE)
    if (isUp) {
      await $.ui.close({ id: PANE })
      await $.store.set(PANE_OPEN, false)

      return { text: '会话面板已关闭。' }
    }
    await refresh($)
    await $.ui.open({ id: PANE, title: TITLE })
    await $.store.set(PANE_OPEN, true)

    return { text: '会话面板已打开。' }
  })

  // The pane's own close mark counts as closing it everywhere.
  on('ui.close', async ($, e, next) => {
    if (e.id === PANE && e.origin.kind === 'person') await $.store.set(PANE_OPEN, false)

    return next(e)
  })

  on('session.measure', async ($, e, next) => {
    const result = await next(e)
    // Every reading, not only a moved one, so the menu bar app's "updated" stays true.
    if (e.rateLimits.length > 0) void writeUsage($, e.rateLimits)

    return result
  })

  on('ui.render', { component: 'Pane', requestId: PANE }, async ($, e) => {
    const table = $.ui.resolve(e)
    const { Box, Text, Button, Markdown } = table
    const Svg = 'Svg' in table ? table.Svg : undefined
    const all = await read($, sessions)
    const open = await read($, expanded)
    const problem = await read($, error)
    const marks = new Set(await read($, unread))
    const now = await $.clock.now()

    const chosen = await read($, range)
    const span = RANGES.find(one => one.key === chosen) ?? RANGES[0]!
    const list = all.filter(s => s.isRunning || now - Date.parse(s.lastActivityAt) <= span.ms)
    const statusOf = (s: SessionRow): Status => (s.isRunning ? 'running' : marks.has(s.id) ? 'unread' : 'seen')

    const marker = (status: Status) => {
      if (!Svg) {
        const color = status === 'running' ? 'claude' : status === 'unread' ? 'suggestion' : undefined

        return (
          <Text color={color} dimColor={status === 'seen'}>
            ●
          </Text>
        )
      }
      const source = status === 'running' ? SPINNER : status === 'unread' ? UNREAD_DOT : IDLE_DOT
      const alt = status === 'running' ? '运行中' : status === 'unread' ? '未查看' : '已查看'

      return (
        <Svg
          source={source}
          alt={alt}
          width={12}
          height={12}
          isInteractive={status === 'running' ? true : undefined}
        />
      )
    }

    // Running is bold, unread plain, and a session already looked at dim.
    // `scope` keeps keys apart where one session is drawn in two places.
    const row = (s: SessionRow, note: string, scope: string) => {
      const status = statusOf(s)
      const href = `${PRESS_BASE}open/${encodeURIComponent(s.id)}`
      const label = `[${escapeMarkdown(s.title)}](${href})`

      return (
        <Box key={`${scope}-row-${s.id}`} flexDirection="row" alignItems="center" columnGap="sm">
          <Box flexShrink={0}>{marker(status)}</Box>
          {/* minWidth 0 lets the title wrap instead of widening the pane. */}
          <Box flexGrow={1} flexShrink={1} minWidth={0}>
            {s.link ? (
              <Markdown
                key={`${scope}-title-${s.id}`}
                text={status === 'running' ? `**${label}**` : label}
                dimColor={status === 'seen' ? true : undefined}
                pressableLinks={[href]}
                onLinkPress={() => void openSession($, s)}
              />
            ) : (
              <Text
                wrap="truncate-end"
                weight={status === 'running' ? 'semibold' : 'regular'}
                dimColor={status === 'seen'}
              >
                {s.title}
              </Text>
            )}
          </Box>
          <Box flexShrink={0}>
            <Text size="caption" dimColor tabular wrap="truncate-end">
              {note}
            </Text>
          </Box>
        </Box>
      )
    }

    const groups = new Map<string, { name: string; rows: SessionRow[] }>()
    for (const s of list) {
      const { key, name } = projectOf(s.cwd)
      const group = groups.get(key) ?? { name, rows: [] }
      group.rows.push(s)
      groups.set(key, group)
    }
    const running = list.filter(s => s.isRunning)

    const toggle = (key: string) =>
      update($, expanded, keys => (keys.includes(key) ? keys.filter(k => k !== key) : [...keys, key]))

    const fold = (key: string, label: string) => {
      const href = `${PRESS_BASE}fold/${encodeURIComponent(key)}`

      return (
        <Markdown
          key={`fold-${key}`}
          dimColor
          text={`[${label}](${href})`}
          pressableLinks={[href]}
          onLinkPress={() => void toggle(key)}
        />
      )
    }

    // A row of buttons, the chosen range drawn as the primary one; it wraps
    // in a narrow pane rather than widening it.
    const rangeBar = (
      <Box flexDirection="row" flexWrap="wrap" alignItems="center" justifyContent="space-between" columnGap="sm" rowGap="xs">
        <Text size="caption" dimColor>
          最近活动
        </Text>
        <Box flexDirection="row" flexWrap="wrap" alignItems="center" columnGap="xs" rowGap="xs">
          {RANGES.map(one => (
            <Button
              key={`range-${one.key}`}
              variant={one.key === span.key ? 'primary' : 'secondary'}
              onPress={() => void update($, range, () => one.key)}
            >
              {one.key}
            </Button>
          ))}
        </Box>
      </Box>
    )

    // Room on the right keeps the scroll bar off the times and counts.
    return (
      <Box flexDirection="column" rowGap="md" width="100%" paddingRight="sm">
        {rangeBar}

        {problem !== '' && (
          <Text color="error" size="caption">
            读取会话失败：{problem}
          </Text>
        )}

        <Box flexDirection="column" rowGap="xs">
          <Text size="heading" weight="semibold">
            正在运行 {running.length > 0 ? `(${running.length})` : ''}
          </Text>
          {running.length === 0 && <Text dimColor>没有正在运行的会话</Text>}
          {running.map(s => row(s, projectOf(s.cwd).name, 'running'))}
        </Box>

        {list.length === 0 && <Text dimColor>{span.empty}</Text>}

        {[...groups.entries()].map(([key, group]) => {
          const isOpen = open.includes(key)
          const shown = isOpen
            ? group.rows
            : group.rows.filter((s, i) => i < SHOWN || s.isRunning)
          const hidden = group.rows.length - shown.length

          return (
            <Box key={`project-${key}`} flexDirection="column" rowGap="xs">
              <Box minWidth={0}>
                <Text size="heading" weight="semibold" wrap="truncate-end">
                  {group.name}
                </Text>
              </Box>
              {shown.map(s => row(s, ago(s.lastActivityAt, now), key))}
              {hidden > 0 && fold(key, `see more ▾`)}
              {isOpen && group.rows.length > SHOWN && fold(key, `see less ▴`)}
            </Box>
          )
        })}
      </Box>
    )
  })
}

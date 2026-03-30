import { useMemo, useState } from "react";
import { useBoardStore } from "../store/boardStore";
import { useTheme, t } from "../theme";
import type { CardDto } from "../types";

export default function AllSessionsBar() {
  const { cards, cardsInColumn, selectedProjectPath, setSelectedProject, selectCard, selectedCardId } =
    useBoardStore();
  const [expanded, setExpanded] = useState(false);
  const { theme } = useTheme();
  const c = t(theme);

  const sessionCards = cardsInColumn("all_sessions");

  // Unique projects derived from ALL cards (filter affects both board and bar)
  const projects = useMemo(() => {
    const map = new Map<string, string>();
    for (const card of cards) {
      const path = card.link.projectPath ?? card.session?.projectPath;
      if (path && card.projectName) map.set(path, card.projectName);
    }
    return Array.from(map.entries()).map(([path, name]) => ({ path, name }));
  }, [cards]);

  return (
    <div
      className="shrink-0"
      style={{ borderTop: `1px solid ${c.border}`, background: c.bgHeader }}
    >
      {/* Bar header — always visible */}
      <div
        className="flex items-center gap-3 px-4 h-10 select-none"
        style={{ cursor: "default" }}
      >
        {/* Toggle */}
        <button
          onClick={() => setExpanded((v) => !v)}
          className="flex items-center gap-2 shrink-0"
          style={{ color: c.textMuted }}
          title={expanded ? "Collapse archive" : "Expand archive"}
        >
          <svg
            className="w-3.5 h-3.5 transition-transform duration-200"
            style={{ transform: expanded ? "rotate(0deg)" : "rotate(180deg)" }}
            fill="none"
            viewBox="0 0 24 24"
            stroke="currentColor"
            strokeWidth={2.5}
          >
            <path strokeLinecap="round" strokeLinejoin="round" d="M19 9l-7 7-7-7" />
          </svg>
          <span className="text-[13px] font-semibold" style={{ color: c.textPrimary }}>
            All Sessions
          </span>
          <span
            className="text-[11px] font-medium px-1.5 py-0.5 rounded-full"
            style={{ background: "#6b728018", color: "#6b7280" }}
          >
            {sessionCards.length}
          </span>
        </button>

        {/* Divider */}
        {projects.length > 0 && (
          <div className="w-px h-4 shrink-0" style={{ background: c.border }} />
        )}

        {/* Project filter pills */}
        {projects.length > 0 && (
          <div className="flex items-center gap-1.5 overflow-x-auto" style={{ scrollbarWidth: "none" }}>
            <button
              onClick={() => setSelectedProject(null)}
              className="px-2.5 py-0.5 rounded-full text-[12px] font-medium transition-colors shrink-0"
              style={
                selectedProjectPath === null
                  ? { background: "#4f8ef7", color: "#fff" }
                  : { background: c.bgAccent("0.06"), color: c.textMuted }
              }
            >
              All
            </button>
            {projects.map(({ path, name }) => (
              <button
                key={path}
                onClick={() => setSelectedProject(selectedProjectPath === path ? null : path)}
                className="px-2.5 py-0.5 rounded-full text-[12px] font-medium transition-colors shrink-0 truncate max-w-[140px]"
                style={
                  selectedProjectPath === path
                    ? { background: "#4f8ef7", color: "#fff" }
                    : { background: c.bgAccent("0.06"), color: c.textMuted }
                }
                title={path}
              >
                {name}
              </button>
            ))}
          </div>
        )}
      </div>

      {/* Expanded card grid */}
      {expanded && (
        <div
          className="overflow-y-auto px-3 pb-3"
          style={{ maxHeight: 220 }}
        >
          {sessionCards.length === 0 ? (
            <div className="flex items-center justify-center py-8">
              <span className="text-[13px]" style={{ color: c.textDim }}>
                No archived sessions
              </span>
            </div>
          ) : (
            <div className="grid gap-2" style={{ gridTemplateColumns: "repeat(auto-fill, minmax(220px, 1fr))" }}>
              {sessionCards.map((card) => (
                <ArchiveCard
                  key={card.id}
                  card={card}
                  isSelected={selectedCardId === card.id}
                  onSelect={() => selectCard(selectedCardId === card.id ? null : card.id)}
                  theme={theme}
                  c={c}
                />
              ))}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function ArchiveCard({
  card,
  isSelected,
  onSelect,
  theme,
  c,
}: {
  card: CardDto;
  isSelected: boolean;
  onSelect: () => void;
  theme: string;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  c: any;
}) {
  const hasPR = card.link.prLinks.length > 0;
  const hasBranch = !!card.link.worktreeLink?.branch;
  const hasIssue = !!card.link.issueLink;
  const prStatus = card.link.prLinks[0]?.status;
  const prStatusColor =
    prStatus === "MERGED" ? "#a371f7" : prStatus === "CLOSED" ? "#f85149" : "#3fb950";

  return (
    <div
      onClick={onSelect}
      className="rounded-lg px-3 py-2.5 cursor-pointer select-none transition-colors"
      style={{
        background: isSelected ? c.bgCardSelected : c.bgCard,
        border: `1px solid ${isSelected ? c.borderCardSelected : c.borderCard}`,
      }}
      onMouseEnter={(e) => {
        if (!isSelected) {
          e.currentTarget.style.background = c.bgCardHover;
          e.currentTarget.style.borderColor = c.borderBright;
        }
      }}
      onMouseLeave={(e) => {
        if (!isSelected) {
          e.currentTarget.style.background = c.bgCard;
          e.currentTarget.style.borderColor = c.borderCard;
        }
      }}
    >
      <p className="text-[13px] leading-snug line-clamp-2 font-medium" style={{ color: c.textPrimary }}>
        {card.displayTitle}
      </p>
      {card.projectName && (
        <p className="text-[12px] mt-0.5 truncate" style={{ color: c.textMuted }}>
          {card.projectName}
        </p>
      )}
      <div className="flex flex-wrap items-center gap-1.5 mt-1.5">
        {hasBranch && (
          <Badge text={card.link.worktreeLink!.branch!} color="#4f8ef7" theme={theme} />
        )}
        {hasPR && (
          <Badge text={`PR #${card.link.prLinks[0].number}`} color={prStatusColor} theme={theme} />
        )}
        {hasIssue && (
          <Badge text={`#${card.link.issueLink!.number}`} color="#d29922" theme={theme} />
        )}
        <span className="flex-1" />
        <span className="text-[11px]" style={{ color: c.textDim }}>
          {card.relativeTime}
        </span>
      </div>
    </div>
  );
}

function Badge({ text, color, theme }: { text: string; color: string; theme: string }) {
  return (
    <span
      className="inline-flex items-center px-1.5 py-0.5 rounded text-[11px] font-medium truncate max-w-[100px]"
      style={{ background: color + (theme === "dark" ? "18" : "15"), color }}
    >
      {text}
    </span>
  );
}

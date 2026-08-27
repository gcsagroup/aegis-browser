export function ToggleRow({
  label,
  checked,
  onChange,
  hint,
}: {
  label: string;
  checked: boolean;
  onChange: (next: boolean) => void;
  hint?: string;
}) {
  return (
    <div className="aegis-row" style={{ marginBottom: 8 }}>
      <div>
        <div className="aegis-toggle">
          <input
            type="checkbox"
            checked={checked}
            onChange={(e) => onChange(e.target.checked)}
          />
          <span>{label}</span>
        </div>
        {hint ? <div className="aegis-muted">{hint}</div> : null}
      </div>
    </div>
  );
}

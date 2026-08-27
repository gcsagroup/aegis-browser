export function StatGrid({
  items,
}: {
  items: { label: string; value: number | string }[];
}) {
  return (
    <div className="aegis-stats">
      {items.map((item) => (
        <div className="aegis-stat" key={item.label}>
          <strong>{item.value}</strong>
          <span>{item.label}</span>
        </div>
      ))}
    </div>
  );
}

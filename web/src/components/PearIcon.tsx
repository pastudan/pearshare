export default function PearIcon({ size = 24 }: { size?: number }) {
  return (
    <img
      src="/pear.png"
      alt="PearShare"
      width={size}
      height={size}
      style={{ display: "inline-block", verticalAlign: "middle" }}
    />
  );
}

export default function BrandMark({ small = false }) {
  return (
    <span className={`brand-mark ${small ? 'brand-mark--small' : ''}`} aria-hidden="true">
      <span className="brand-mark__ring" />
      <span className="brand-mark__cross brand-mark__cross--h" />
      <span className="brand-mark__cross brand-mark__cross--v" />
      <span className="brand-mark__dot" />
    </span>
  )
}

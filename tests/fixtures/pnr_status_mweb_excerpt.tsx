import { forwardRef, lazy, ReactNode, Suspense } from 'react'
import { useNavigate, useParams } from 'react-router'

const HotelCrossSellContainer = lazy(() => import('./HotelCrossSell'))

function Demo({
  pnrResponse,
  ctProResponse,
  pnr,
  isLoading,
  navigate,
  trainNo,
  travelClass,
  setShowCPDialog,
}) {
  return (
    <>
      <OtherSEO
        isDesktop={false}
        trainNumber={trainNo}
        travelClass={travelClass}
        setShowCPDialog={setShowCPDialog}
        navigate={navigate}
        pnrResponse={pnrResponse}
      />
      <HotelCrossSellContainer pnrResponse={pnrResponse} />
      <Header
        isCTProPlanActive={ctProResponse?.isActiveProSubscription}
        pnr={pnr}
        showAppDownload={!isLoading}
      />
    </>
  )
}

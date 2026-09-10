<?php
declare(strict_types=1);
namespace OCA\ApplePhotosConnector\Command;
use OCA\ApplePhotosConnector\Service\AlbumMembershipService;
use Symfony\Component\Console\Command\Command;
use Symfony\Component\Console\Input\{InputArgument,InputInterface};
use Symfony\Component\Console\Output\OutputInterface;
final class AlbumTestAddMembershipCommand extends Command {
    public function __construct(private AlbumMembershipService $service){parent::__construct('apple-photos-connector:album:test-add-membership');}
    protected function configure():void{$this->setDescription('Add one imported file to one resolved Apple album (development test)')->addArgument('sourceAlbumId',InputArgument::REQUIRED)->addArgument('assetId',InputArgument::REQUIRED)->addArgument('userId',InputArgument::REQUIRED);}
    protected function execute(InputInterface $i,OutputInterface $o):int{try{$r=$this->service->add((int)$i->getArgument('sourceAlbumId'),(int)$i->getArgument('assetId'),(string)$i->getArgument('userId'));foreach(['created_or_reused','album_id','file_id']as$k)$o->writeln($k.': '.$r[$k]);return Command::SUCCESS;}catch(\Throwable $e){$o->writeln('<error>'.$e->getMessage().'</error>');return Command::FAILURE;}}
}
